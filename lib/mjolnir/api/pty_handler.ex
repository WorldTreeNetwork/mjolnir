defmodule Mjolnir.API.PtyHandler do
  @moduledoc """
  WebSocket handler bridging client WebSocket to vsock PTY channel.

  Binary frames carry PTY I/O. Text frames carry control messages (resize).
  """

  @behaviour WebSock
  require Logger

  defstruct [:vm_id, :channel, :conn_pid]

  # Bandit's WebSocket idle timer is "no *client* frames". PTY output does
  # not reset it, so a 60s timeout killed long-running commands and idle
  # tabs. Infinity here; keepalives below keep Cloudflare/nginx from
  # dropping a quiet socket (~100s).
  @idle_timeout :infinity
  @ping_ms 20_000

  # Called by the router to initiate WebSocket upgrade.
  # `session`, when given, is a tmux session name the PTY attaches to — several
  # sockets naming the same session share one terminal. Already validated by the
  # router; nil means a private shell.
  def call(conn, vm_id, session \\ nil) do
    # The conn has already been through Auth plug, so we can check scopes
    # Look up the VM
    case Mjolnir.VM.get(vm_id) do
      {:ok, vm} ->
        conn
        |> WebSockAdapter.upgrade(
          __MODULE__,
          %{vm: vm, vm_id: vm_id, session: session},
          timeout: @idle_timeout
        )

      {:error, :not_found} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{error: "not_found"}))

      # Wedged/unresponsive VM GenServer (mjolnir-8ie) — exists but unreachable.
      {:error, :unreachable} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{error: "vm_unreachable"}))
    end
  end

  @impl WebSock
  def init(%{vm: vm, vm_id: vm_id} = args) do
    session = Map.get(args, :session)

    Logger.info(
      "PTY WebSocket init for VM #{vm_id}, vsock_conn=#{inspect(vm.vsock_conn)}, " <>
        "session=#{inspect(session)}"
    )

    # Open PTY channel through the VM's vsock connection
    case Mjolnir.Vsock.Connection.open_pty(vm.vsock_conn, 24, 80, 10_000, session) do
      {:ok, channel_id} ->
        # Register this process to receive data from the channel
        :ok =
          Mjolnir.Vsock.Connection.register_channel_handler(
            vm.vsock_conn,
            channel_id,
            self()
          )

        state = %__MODULE__{
          vm_id: vm_id,
          channel: channel_id,
          conn_pid: vm.vsock_conn
        }

        Logger.info("PTY WebSocket opened for VM #{vm_id}, channel #{channel_id}")
        Process.send_after(self(), :ws_ping, @ping_ms)
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to open PTY for VM #{vm_id}: #{inspect(reason)}")
        {:stop, :normal, {1011, "Failed to open PTY: #{inspect(reason)}"}}
    end
  end

  @impl WebSock
  def handle_in({data, opcode: :binary}, state) do
    # Binary frame = PTY stdin
    Mjolnir.Vsock.Connection.send_data(state.conn_pid, state.channel, data)
    {:ok, state}
  end

  def handle_in({data, opcode: :text}, state) do
    # Text frame = control message
    case Jason.decode(data) do
      {:ok, %{"type" => "resize", "rows" => rows, "cols" => cols}} ->
        {rows, cols} = clamp_dimensions(rows, cols)
        resize_msg = Mjolnir.Vsock.Protocol.pty_resize_request(state.channel, rows, cols)
        Mjolnir.Vsock.Connection.send_control_message(state.conn_pid, resize_msg)
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  @impl WebSock
  def handle_info({:vsock_data, _channel, data}, state) do
    # PTY output -> send as binary WebSocket frame
    Logger.debug("PTY output #{byte_size(data)} bytes on channel #{state.channel}")
    {:push, {:binary, data}, state}
  end

  def handle_info({:pty_closed, _channel}, state) do
    Logger.debug("PTY channel #{state.channel} closed by guest")
    {:stop, :normal, state}
  end

  def handle_info(:ws_ping, state) do
    Process.send_after(self(), :ws_ping, @ping_ms)
    {:push, {:ping, <<>>}, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message in PtyHandler: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(_reason, state) do
    if state.conn_pid && state.channel do
      Logger.debug("Closing PTY channel #{state.channel} for VM #{state.vm_id}")
      Mjolnir.Vsock.Connection.close_pty(state.conn_pid, state.channel)
      Mjolnir.Vsock.Connection.unregister_channel_handler(state.conn_pid, state.channel)
    end

    :ok
  end

  # Max terminal dimensions - prevents unreasonable allocations in the guest PTY
  @max_pty_dimension 500

  defp clamp_dimensions(rows, cols) do
    {clamp(rows, 1, @max_pty_dimension), clamp(cols, 1, @max_pty_dimension)}
  end

  defp clamp(val, min_val, max_val) when is_integer(val), do: val |> max(min_val) |> min(max_val)
  defp clamp(_val, min_val, _max_val), do: min_val
end
