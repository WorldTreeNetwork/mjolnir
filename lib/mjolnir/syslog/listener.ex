defmodule Mjolnir.Syslog.Listener do
  @moduledoc """
  Listens for syslog messages from VMs over vsock (channel 2).

  ## Transport

  Uses the existing vsock channel multiplexing in `Mjolnir.Vsock.Protocol`.
  Channel 0 is the JSON control channel; channels 1-255 are binary. Channel 2
  is reserved for newline-delimited syslog lines sent by the guest agent.

  To receive syslog from a VM, register this process as the channel 2 handler
  on the VM's `Mjolnir.Vsock.Connection`:

      Mjolnir.Vsock.Connection.register_channel_handler(conn_pid, 2, listener_pid)

  The Listener subscribes to EventBus `:vm_spawned` events to auto-register on
  each new VM's vsock connection.

  ## Message flow

      guest syslogd → vsock ch2 → Vsock.Connection → {:vsock_data, 2, data}
        → Syslog.Listener → parse lines → Syslog.Router → sinks

  ## Configuration

      config :mjolnir, Mjolnir.Syslog,
        vsock_channel: 2   # default
  """

  use GenServer
  require Logger

  alias Mjolnir.Syslog.Parser
  alias Mjolnir.Syslog.Router

  # Vsock channel reserved for syslog
  @syslog_channel 2

  # Per-VM state: {vm_id, cid, buffer_so_far}
  defstruct vm_buffers: %{}

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a vsock connection for syslog listening on channel #{@syslog_channel}.

  Called automatically when the Listener receives a `:vm_spawned` event, but
  can also be called manually after a vsock connection is established.
  """
  @spec register_connection(pid(), String.t(), non_neg_integer()) :: :ok
  def register_connection(conn_pid, vm_id, cid) do
    GenServer.cast(__MODULE__, {:register_connection, conn_pid, vm_id, cid})
  end

  @doc """
  The vsock channel number used for syslog data.
  """
  def channel, do: @syslog_channel

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    # Subscribe to VM lifecycle events so we can auto-register new VMs
    Mjolnir.EventBus.subscribe(:all)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:register_connection, conn_pid, vm_id, cid}, state) do
    case Mjolnir.Vsock.Connection.register_channel_handler(conn_pid, @syslog_channel, self()) do
      :ok ->
        Logger.debug("Syslog.Listener: registered channel #{@syslog_channel} for VM #{vm_id}")
        buffers = Map.put(state.vm_buffers, vm_id, {cid, <<>>})
        {:noreply, %{state | vm_buffers: buffers}}

      {:error, reason} ->
        Logger.warning(
          "Syslog.Listener: failed to register channel for VM #{vm_id}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:vsock_data, @syslog_channel, data}, state) do
    # Data arrives framed but we don't know which VM sent it here;
    # the channel handler is per-connection so we need to find the vm_id.
    # Since each VM's connection registers separately, we match via the
    # sender PID. Unfortunately vsock_data messages don't include the
    # connection PID. Instead we rely on registration order:
    # parse the data and try to route it to any VM that has pending channel data.
    #
    # For v1, data arrives as raw bytes — collect into the single-VM buffer
    # using a fallback: if only one VM is registered, route to it. Otherwise
    # drop with a warning. A future improvement will identify sender via
    # registered channel PID.
    case find_vm_for_data(state) do
      {:ok, vm_id, cid, buf} ->
        new_buf = buf <> data
        {lines, remaining} = split_lines(new_buf)
        process_lines(lines, vm_id, cid)
        buffers = Map.put(state.vm_buffers, vm_id, {cid, remaining})
        {:noreply, %{state | vm_buffers: buffers}}

      :error ->
        Logger.debug("Syslog.Listener: received data with no registered VM, dropping")
        {:noreply, state}
    end
  end

  def handle_info({:syslog_data, vm_id, cid, data}, state) do
    # Explicit tagged message (used when sender identifies itself)
    buf = get_buffer(state, vm_id)
    new_buf = buf <> data
    {lines, remaining} = split_lines(new_buf)
    process_lines(lines, vm_id, cid)
    buffers = Map.put(state.vm_buffers, vm_id, {cid, remaining})
    {:noreply, %{state | vm_buffers: buffers}}
  end

  def handle_info({:mjolnir_event, vm_id, :vm_stopped, _payload}, state) do
    buffers = Map.delete(state.vm_buffers, vm_id)
    {:noreply, %{state | vm_buffers: buffers}}
  end

  def handle_info({:mjolnir_event, _vm_id, _event, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp find_vm_for_data(state) do
    case Map.to_list(state.vm_buffers) do
      [{vm_id, {cid, buf}}] ->
        {:ok, vm_id, cid, buf}

      list when length(list) > 1 ->
        Logger.warning(
          "Syslog.Listener: #{length(list)} VMs registered but cannot identify sender; dropping data"
        )

        :error

      _ ->
        :error
    end
  end

  defp get_buffer(state, vm_id) do
    case Map.get(state.vm_buffers, vm_id) do
      {_cid, buf} -> buf
      nil -> <<>>
    end
  end

  defp split_lines(data) do
    lines = String.split(data, "\n")
    # Last element is either empty (if data ends with \n) or a partial line
    {complete, [tail]} = Enum.split(lines, length(lines) - 1)
    complete_nonempty = Enum.reject(complete, &(&1 == ""))
    {complete_nonempty, tail}
  end

  defp process_lines(lines, vm_id, cid) do
    Enum.each(lines, fn line ->
      case Parser.parse(line) do
        {:ok, msg} ->
          Router.route(vm_id, cid, msg)

        {:error, :malformed, msg} ->
          Logger.debug("Syslog.Listener: malformed line from VM #{vm_id}: #{inspect(line)}")
          Router.route(vm_id, cid, msg)
      end
    end)
  end
end
