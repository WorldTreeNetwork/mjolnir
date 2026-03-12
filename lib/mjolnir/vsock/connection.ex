defmodule Mjolnir.Vsock.Connection do
  @moduledoc """
  Manages vsock connection to a guest VM.

  vsock uses Unix domain sockets on the host side, where the hypervisor
  (Cloud Hypervisor or Firecracker) acts as a proxy to the guest's vsock device.
  """

  use GenServer
  require Logger

  alias Mjolnir.Vsock.Protocol

  defstruct [
    :vm_id,
    :socket_path,
    :socket,
    :pending_requests,
    buffer: <<>>,
    channel_handlers: %{}
  ]

  # Port the guest agent listens on
  @vsock_port 5000

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute a command in the guest and wait for response.
  """
  def exec(pid, command, timeout \\ 30_000) do
    GenServer.call(pid, {:exec, command}, timeout)
  end

  @doc """
  Ping the guest agent to check connectivity.
  """
  def ping(pid, timeout \\ 5_000) do
    GenServer.call(pid, :ping, timeout)
  end

  @doc """
  Open a new PTY session in the guest.
  Returns {:ok, channel_id} on success.
  """
  def open_pty(pid, rows \\ 24, cols \\ 80, timeout \\ 10_000) do
    GenServer.call(pid, {:open_pty, rows, cols}, timeout)
  end

  @doc """
  Close a PTY session.
  """
  def close_pty(pid, channel) do
    GenServer.cast(pid, {:close_pty, channel})
  end

  @doc """
  Send binary data on a specific channel.
  """
  def send_data(pid, channel, data) do
    GenServer.cast(pid, {:send_data, channel, data})
  end

  @doc """
  Send a control message (JSON) on channel 0.
  """
  def send_control_message(pid, message) do
    GenServer.cast(pid, {:send_control_message, message})
  end

  @doc """
  Deliver a message from another VM into the guest's inbox.
  """
  def deliver_message(pid, from_vm_id, payload) do
    GenServer.cast(pid, {:send_control_message, Protocol.deliver_message(from_vm_id, payload)})
  end

  @doc "Open or ensure a terminal session in the guest."
  def terminal_open(pid, session_name) do
    GenServer.call(pid, {:terminal_open, session_name})
  end

  @doc "Read terminal content from the guest."
  def terminal_read(pid, session_name, scrollback_lines \\ 100) do
    GenServer.call(pid, {:terminal_read, session_name, scrollback_lines})
  end

  @doc "Send command or keys to terminal in the guest."
  def terminal_send(pid, session_name, command \\ nil, keys \\ nil) do
    GenServer.call(pid, {:terminal_send, session_name, command, keys})
  end

  @doc "Send command and wait for output from the guest."
  def terminal_send_and_read(pid, session_name, command, timeout_ms \\ 30_000) do
    GenServer.call(
      pid,
      {:terminal_send_and_read, session_name, command, timeout_ms},
      timeout_ms + 10_000
    )
  end

  @doc "List terminal sessions in the guest."
  def terminal_list(pid) do
    GenServer.call(pid, :terminal_list)
  end

  @doc "Close a terminal session in the guest."
  def terminal_close(pid, session_name) do
    GenServer.call(pid, {:terminal_close, session_name})
  end

  @doc """
  Register a process to receive data for a specific channel.
  The handler will receive messages of the form {:vsock_data, channel, data}.
  """
  def register_channel_handler(pid, channel, handler_pid) do
    GenServer.call(pid, {:register_channel_handler, channel, handler_pid})
  end

  @doc """
  Unregister a channel handler.
  """
  def unregister_channel_handler(pid, channel) do
    GenServer.call(pid, {:unregister_channel_handler, channel})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      vm_id: opts.vm_id,
      socket_path: opts.socket_path,
      pending_requests: %{}
    }

    case connect(state) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:exec, command}, from, state) do
    request = Protocol.exec_request(command)
    request_id = request["id"]

    case send_message(state.socket, request, 0) do
      :ok ->
        # Store pending request to match response
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:ping, from, state) do
    request_id = UUID.uuid4()

    case send_message(state.socket, Map.put(Protocol.ping(), "id", request_id), 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_pty, rows, cols}, from, state) do
    request = Protocol.pty_open_request(rows, cols)
    request_id = request["id"]

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_open, session_name}, from, state) do
    request_id = UUID.uuid4()
    request = %{"type" => "terminal_open", "id" => request_id, "session_name" => session_name}

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_read, session_name, scrollback_lines}, from, state) do
    request_id = UUID.uuid4()

    request = %{
      "type" => "terminal_read",
      "id" => request_id,
      "session_name" => session_name,
      "scrollback_lines" => scrollback_lines
    }

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_send, session_name, command, keys}, from, state) do
    request_id = UUID.uuid4()
    request = %{"type" => "terminal_send", "id" => request_id, "session_name" => session_name}
    request = if command, do: Map.put(request, "command", command), else: request
    request = if keys, do: Map.put(request, "keys", keys), else: request

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_send_and_read, session_name, command, timeout_ms}, from, state) do
    request_id = UUID.uuid4()

    request = %{
      "type" => "terminal_send_and_read",
      "id" => request_id,
      "session_name" => session_name,
      "command" => command,
      "timeout_ms" => timeout_ms
    }

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:terminal_list, from, state) do
    request_id = UUID.uuid4()
    request = %{"type" => "terminal_list", "id" => request_id}

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminal_close, session_name}, from, state) do
    request_id = UUID.uuid4()
    request = %{"type" => "terminal_close", "id" => request_id, "session_name" => session_name}

    case send_message(state.socket, request, 0) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_channel_handler, channel, handler_pid}, _from, state) do
    handlers = Map.put(state.channel_handlers, channel, handler_pid)
    {:reply, :ok, %{state | channel_handlers: handlers}}
  end

  def handle_call({:unregister_channel_handler, channel}, _from, state) do
    handlers = Map.delete(state.channel_handlers, channel)
    {:reply, :ok, %{state | channel_handlers: handlers}}
  end

  @impl true
  def handle_cast({:close_pty, channel}, state) do
    request = Protocol.pty_close_request(channel)
    send_message(state.socket, request, 0)
    {:noreply, state}
  end

  def handle_cast({:send_data, channel, data}, state) do
    # Send binary data on the specified channel
    frame = Protocol.encode(data, channel)
    :gen_tcp.send(state.socket, frame)
    {:noreply, state}
  end

  def handle_cast({:send_control_message, message}, state) do
    # Send a control message on channel 0 (used by pty_channel for resize)
    send_message(state.socket, message, 0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    # Accumulate data in buffer and process complete messages
    buffer = state.buffer <> data
    {new_buffer, state} = process_buffer(buffer, state)
    {:noreply, %{state | buffer: new_buffer}}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("vsock connection closed for VM #{state.vm_id}")
    {:stop, :connection_closed, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("vsock error for VM #{state.vm_id}: #{inspect(reason)}")
    {:stop, {:tcp_error, reason}, state}
  end

  defp process_buffer(buffer, state) do
    case Protocol.decode_frame(buffer) do
      {:ok, channel, payload, remaining} ->
        state =
          if channel == 0 do
            handle_control_message(payload, state)
          else
            handle_channel_data(channel, payload, state)
          end

        process_buffer(remaining, state)

      {:incomplete, buffer} ->
        {buffer, state}
    end
  end

  defp handle_channel_data(channel, data, state) do
    case Map.get(state.channel_handlers, channel) do
      nil ->
        Logger.warning("Data on unregistered channel #{channel}")
        state

      pid ->
        send(pid, {:vsock_data, channel, data})
        state
    end
  end

  defp handle_control_message(json, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "exec_response", "id" => id} = response} ->
        result =
          if response["exit_code"] == 0 do
            {:ok, response["stdout"]}
          else
            {:error, {:exit_code, response["exit_code"], response["stderr"]}}
          end

        reply_to_pending(state, id, result, "exec_response")

      {:ok, %{"type" => "pong", "id" => id}} ->
        reply_to_pending(state, id, :pong, "pong")

      {:ok, %{"type" => "configure_iroh_response", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "configure_iroh_response")

      {:ok, %{"type" => "pty_opened", "id" => id, "channel" => channel}} ->
        reply_to_pending(state, id, {:ok, channel}, "pty_opened")

      {:ok, %{"type" => "pty_closed", "channel" => channel}} ->
        # Notify handler and clean up
        case Map.get(state.channel_handlers, channel) do
          nil -> :ok
          pid -> send(pid, {:pty_closed, channel})
        end

        handlers = Map.delete(state.channel_handlers, channel)
        %{state | channel_handlers: handlers}

      {:ok, %{"type" => "spawn_sub_agent_response", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "spawn_sub_agent_response")

      {:ok, %{"type" => "snapshot_self_response", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "snapshot_self_response")

      {:ok, %{"type" => "event_ack", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "event_ack")

      {:ok, %{"type" => "spawn_sub_agent", "id" => id, "opts" => opts}} ->
        Logger.info("Guest requesting sub-agent spawn: #{id}")
        conn_pid = self()

        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          response =
            try do
              case Mjolnir.VM.spawn(atomize_opts(opts)) do
                {:ok, %{id: new_vm_id}} ->
                  %{"type" => "spawn_sub_agent_response", "id" => id, "vm_id" => new_vm_id}

                {:error, reason} ->
                  %{
                    "type" => "spawn_sub_agent_response",
                    "id" => id,
                    "vm_id" => "",
                    "error" => inspect(reason)
                  }
              end
            catch
              kind, reason ->
                Logger.error("Sub-agent spawn crashed: #{inspect(kind)}: #{inspect(reason)}")

                %{
                  "type" => "spawn_sub_agent_response",
                  "id" => id,
                  "vm_id" => "",
                  "error" => inspect(reason)
                }
            end

          Mjolnir.Vsock.Connection.send_control_message(conn_pid, response)
        end)

        state

      {:ok, %{"type" => "snapshot_self", "id" => id, "name" => name}} ->
        Logger.info("Guest requesting self-snapshot: #{name}")
        conn_pid = self()
        vm_id = state.vm_id

        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          response =
            try do
              case Mjolnir.VM.snapshot(vm_id, name) do
                {:ok, _} ->
                  %{"type" => "snapshot_self_response", "id" => id, "ok" => true}

                {:error, _} ->
                  %{"type" => "snapshot_self_response", "id" => id, "ok" => false}
              end
            catch
              kind, reason ->
                Logger.error("Snapshot crashed: #{inspect(kind)}: #{inspect(reason)}")
                %{"type" => "snapshot_self_response", "id" => id, "ok" => false}
            end

          Mjolnir.Vsock.Connection.send_control_message(conn_pid, response)
        end)

        state

      {:ok, %{"type" => "emit_event", "id" => id, "event" => event, "payload" => payload}}
      when is_binary(event) and event != "" ->
        Logger.debug("Guest emitting event: #{event}")

        Mjolnir.EventBus.publish(state.vm_id, :agent_event, %{
          "event" => event,
          "payload" => payload
        })

        send_message(state.socket, %{"type" => "event_ack", "id" => id}, 0)
        state

      {:ok, %{"type" => "emit_event", "id" => id, "event" => event}} ->
        Logger.warning("Guest emitted event with invalid name: #{inspect(event)}")
        send_message(state.socket, %{"type" => "event_ack", "id" => id}, 0)
        state

      {:ok,
       %{"type" => "send_message", "id" => id, "target_vm_id" => target, "payload" => payload}} ->
        Logger.info("Guest requesting message send to #{target}")
        conn_pid = self()
        source_vm_id = state.vm_id

        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          {ok, error} =
            case Mjolnir.VM.deliver_message(target, source_vm_id, payload) do
              :ok -> {true, nil}
              {:error, reason} -> {false, inspect(reason)}
            end

          resp = Protocol.send_message_response(id, ok, error)
          Mjolnir.Vsock.Connection.send_control_message(conn_pid, resp)
        end)

        state

      {:ok, %{"type" => "signal_done", "id" => id}} ->
        Logger.info("Guest signaling done for VM #{state.vm_id}")
        send_message(state.socket, Protocol.signal_done_ack(id, true), 0)
        vm_id = state.vm_id

        Task.Supervisor.start_child(Mjolnir.TaskSupervisor, fn ->
          Mjolnir.VM.handle_done(vm_id)
        end)

        state

      {:ok, %{"type" => "deliver_message_ack", "id" => _id}} ->
        # No-op, just confirmation the guest buffered the message
        state

      {:ok, %{"type" => "send_message_response", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "send_message_response")

      {:ok, %{"type" => "signal_done_ack", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "signal_done_ack")

      {:ok, %{"type" => "iroh_ready"} = msg} ->
        # Guest proactively sends this when Iroh is ready - just log and ignore
        # The VM.ex module handles this during boot via await_iroh_ready
        Logger.debug("Received iroh_ready (ignoring in connection): #{msg["node_id"]}")
        state

      {:ok, %{"type" => "terminal_opened", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_opened")

      {:ok, %{"type" => "terminal_output", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_output")

      {:ok, %{"type" => "terminal_sent", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_sent")

      # CRITICAL: terminal_command_ack is a NO-OP — do NOT call reply_to_pending!
      # The pending request must remain until terminal_command_output arrives.
      {:ok, %{"type" => "terminal_command_ack", "id" => id, "status" => status}} ->
        Logger.debug("Terminal command ack for #{id}: #{status}")
        state

      # terminal_command_output is the REAL result from the spawned tokio task
      {:ok, %{"type" => "terminal_command_output", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_command_output")

      {:ok, %{"type" => "terminal_sessions", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_sessions")

      {:ok, %{"type" => "terminal_closed", "id" => id} = response} ->
        reply_to_pending(state, id, {:ok, response}, "terminal_closed")

      {:ok, %{"type" => "terminal_error", "id" => id} = response} ->
        reply_to_pending(state, id, {:error, response}, "terminal_error")

      {:ok, other} ->
        Logger.warning("Unknown vsock message type: #{inspect(other)}")
        state

      {:error, reason} ->
        Logger.error("Failed to decode vsock JSON: #{inspect(reason)}")
        state
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp reply_to_pending(state, id, result, type_name) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received #{type_name} for unknown request: #{id}")
        state

      {from, pending} ->
        GenServer.reply(from, result)
        %{state | pending_requests: pending}
    end
  end

  defp connect(state) do
    # Connect to the hypervisor's vsock proxy socket
    # The socket path is provided by the hypervisor's vsock configuration
    # We connect to the UDS, then send "CONNECT <port>\n"
    opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect({:local, state.socket_path}, 0, opts) do
      {:ok, socket} ->
        # Send CONNECT command to establish vsock connection to guest port
        connect_cmd = "CONNECT #{@vsock_port}\n"

        case :gen_tcp.send(socket, connect_cmd) do
          :ok ->
            # Wait for "OK <local_port>\n" response
            case :gen_tcp.recv(socket, 0, 5000) do
              {:ok, response} ->
                if String.starts_with?(response, "OK") do
                  # Switch to active mode for async message handling
                  :inet.setopts(socket, active: true)
                  Logger.debug("Connected to vsock for VM #{state.vm_id}")
                  {:ok, socket}
                else
                  Logger.error("Vsock connect rejected: #{inspect(response)}")
                  :gen_tcp.close(socket)
                  {:error, {:vsock_rejected, response}}
                end

              {:error, reason} ->
                Logger.error("Vsock connect response error: #{inspect(reason)}")
                :gen_tcp.close(socket)
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to send vsock connect: #{inspect(reason)}")
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to connect to vsock UDS: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_message(socket, message, channel) do
    data = Protocol.encode(message, channel)
    :gen_tcp.send(socket, data)
  end

  defp atomize_opts(opts) when is_map(opts) do
    opts
    |> Enum.flat_map(fn {k, v} ->
      try do
        [{String.to_existing_atom(k), v}]
      rescue
        ArgumentError ->
          Logger.warning("Dropping unknown option key from guest: #{k}")
          []
      end
    end)
    |> Map.new()
  end

  defp atomize_opts(opts), do: opts
end
