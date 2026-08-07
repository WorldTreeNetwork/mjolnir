defmodule Mjolnir.Vsock.PtyChannel do
  @moduledoc """
  Manages a single PTY session over a vsock channel.

  Bridges between a subscriber process (e.g., WebSocket handler)
  and the vsock connection's binary channel. Handles lifecycle
  events like data flow, resize, and cleanup.
  """

  use GenServer
  require Logger

  alias Mjolnir.Vsock.Connection
  alias Mjolnir.Vsock.Protocol

  defstruct [:conn, :channel, :subscriber]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a PTY channel GenServer.

  Options:
  - `:conn` - The vsock connection PID
  - `:subscriber` - The process that will receive PTY output
  - `:rows` - Initial terminal rows (default: 24)
  - `:cols` - Initial terminal columns (default: 80)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send input to the PTY.
  """
  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end

  @doc """
  Resize the PTY window.
  """
  def resize(pid, rows, cols) do
    GenServer.cast(pid, {:resize, rows, cols})
  end

  @doc """
  Close the PTY session.
  """
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    subscriber = Keyword.fetch!(opts, :subscriber)
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    session = Keyword.get(opts, :session)

    # Open PTY session and get assigned channel
    case Connection.open_pty(conn, rows, cols, 10_000, session) do
      {:ok, channel} ->
        # Register this process as the handler for the channel
        :ok = Connection.register_channel_handler(conn, channel, self())

        Logger.debug("PTY channel #{channel} opened for subscriber #{inspect(subscriber)}")

        {:ok,
         %__MODULE__{
           conn: conn,
           channel: channel,
           subscriber: subscriber
         }}

      {:error, reason} ->
        Logger.error("Failed to open PTY: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    # Send input data to the guest PTY via the channel
    Connection.send_data(state.conn, state.channel, data)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, state) do
    # Send resize request on control channel (channel 0)
    # We need to go through the Connection GenServer for this
    # For now, we'll use GenServer.cast to send the request
    GenServer.cast(
      state.conn,
      {:send_control_message, Protocol.pty_resize_request(state.channel, rows, cols)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:vsock_data, channel, data}, state) when channel == state.channel do
    # Forward PTY output to subscriber
    send(state.subscriber, {:pty_output, data})
    {:noreply, state}
  end

  def handle_info({:pty_closed, channel}, state) when channel == state.channel do
    Logger.debug("PTY channel #{channel} closed by guest")
    send(state.subscriber, :pty_closed)
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Unexpected message in PtyChannel: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Unregister and close the PTY
    Connection.unregister_channel_handler(state.conn, state.channel)
    Connection.close_pty(state.conn, state.channel)
    :ok
  end
end
