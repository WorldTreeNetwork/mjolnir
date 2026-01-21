defmodule Mjolnir.Vsock.Connection do
  @moduledoc """
  Manages vsock connection to a guest VM.

  vsock uses Unix domain sockets on the host side, where Firecracker
  acts as a proxy to the guest's vsock device.
  """

  use GenServer
  require Logger

  alias Mjolnir.Vsock.Protocol

  defstruct [:vm_id, :socket_path, :socket, :pending_requests]

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

    case send_message(state.socket, request) do
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

    case send_message(state.socket, Map.put(Protocol.ping(), "id", request_id)) do
      :ok ->
        pending = Map.put(state.pending_requests, request_id, from)
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    case Protocol.decode(data) do
      {:ok, %{"type" => "exec_response", "id" => id} = response} ->
        case Map.pop(state.pending_requests, id) do
          {nil, _} ->
            Logger.warning("Received response for unknown request: #{id}")
            {:noreply, state}

          {from, pending} ->
            result =
              if response["exit_code"] == 0 do
                {:ok, response["stdout"]}
              else
                {:error, {:exit_code, response["exit_code"], response["stderr"]}}
              end

            GenServer.reply(from, result)
            {:noreply, %{state | pending_requests: pending}}
        end

      {:ok, %{"type" => "pong", "id" => id}} ->
        case Map.pop(state.pending_requests, id) do
          {nil, _} ->
            {:noreply, state}

          {from, pending} ->
            GenServer.reply(from, :pong)
            {:noreply, %{state | pending_requests: pending}}
        end

      {:error, reason} ->
        Logger.error("Failed to decode vsock message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("vsock connection closed for VM #{state.vm_id}")
    {:stop, :connection_closed, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("vsock error for VM #{state.vm_id}: #{inspect(reason)}")
    {:stop, {:tcp_error, reason}, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp connect(state) do
    # Connect to Firecracker's vsock proxy socket
    # The socket path is provided by Firecracker's vsock configuration
    opts = [:binary, active: true, packet: :raw]

    case :gen_tcp.connect({:local, state.socket_path}, @vsock_port, opts) do
      {:ok, socket} ->
        Logger.debug("Connected to vsock for VM #{state.vm_id}")
        {:ok, socket}

      {:error, reason} ->
        Logger.error("Failed to connect to vsock: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_message(socket, message) do
    data = Protocol.encode(message)
    :gen_tcp.send(socket, data)
  end
end
