defmodule Mjolnir.API.PtyHandler do
  @moduledoc """
  WebSocket handler bridging client WebSocket to vsock PTY channel.

  Binary frames carry PTY I/O. Text frames carry control messages (resize).
  """

  @behaviour WebSock
  require Logger

  defstruct [:vm_id, :channel, :conn_pid]

  # Called by the router to initiate WebSocket upgrade
  def call(conn, vm_id) do
    # The conn has already been through Auth plug, so we can check scopes
    # Look up the VM
    case Mjolnir.VM.get(vm_id) do
      {:ok, vm} ->
        conn
        |> WebSockAdapter.upgrade(
          __MODULE__,
          %{vm: vm, vm_id: vm_id},
          timeout: 60_000
        )

      {:error, :not_found} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{error: "not_found"}))
    end
  end

  @impl WebSock
  def init(%{vm: vm, vm_id: vm_id}) do
    Logger.info("PTY WebSocket init for VM #{vm_id}, vsock_conn=#{inspect(vm.vsock_conn)}")

    # Open PTY channel through the VM's vsock connection
    case Mjolnir.Vsock.Connection.open_pty(vm.vsock_conn, 24, 80) do
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
end
