defmodule Mjolnir.Syslog.Router do
  @moduledoc """
  Routes parsed syslog messages to configured sinks.

  Receives `{:syslog_message, vm_id, cid, message}` messages from the
  `Mjolnir.Syslog.Listener` and dispatches to one or more sinks.

  ## Sinks

  - `:eventbus` — publishes `{:mjolnir_event, vm_id, :vm_syslog, message}` on
    `Mjolnir.EventBus`
  - `:logger`   — forwards to Elixir Logger with VM metadata attached

  ## Configuration

      config :mjolnir, Mjolnir.Syslog,
        sinks: [:eventbus, :logger]
  """

  use GenServer
  require Logger

  alias Mjolnir.Syslog.Message

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route a parsed syslog message originating from `vm_id` (CID `cid`).
  """
  @spec route(String.t(), non_neg_integer(), Message.t()) :: :ok
  def route(vm_id, cid, %Message{} = message) do
    GenServer.cast(__MODULE__, {:route, vm_id, cid, message})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    sinks =
      :mjolnir
      |> Application.get_env(:syslog, [])
      |> Keyword.get(:sinks, [:eventbus, :logger])

    {:ok, %{sinks: sinks}}
  end

  @impl true
  def handle_cast({:route, vm_id, _cid, message}, state) do
    Enum.each(state.sinks, fn sink -> dispatch(sink, vm_id, message) end)
    {:noreply, state}
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp dispatch(:eventbus, vm_id, message) do
    Mjolnir.EventBus.publish(vm_id, :vm_syslog, message)
  end

  defp dispatch(:logger, vm_id, message) do
    level = severity_to_level(message.severity)
    tag = message.tag || "syslog"
    pid_info = if message.pid, do: "[#{message.pid}]", else: ""
    text = message.message || message.raw

    Logger.log(level, "[vm=#{vm_id}] #{tag}#{pid_info}: #{text}",
      vm_id: vm_id,
      syslog_facility: message.facility,
      syslog_severity: message.severity,
      syslog_tag: message.tag
    )
  end

  defp dispatch(:file, _vm_id, _message) do
    # Future: append to per-VM log file
    :ok
  end

  defp dispatch(unknown, _vm_id, _message) do
    Logger.warning("Syslog.Router: unknown sink #{inspect(unknown)}")
  end

  defp severity_to_level(:emergency), do: :error
  defp severity_to_level(:alert), do: :error
  defp severity_to_level(:critical), do: :error
  defp severity_to_level(:error), do: :error
  defp severity_to_level(:warning), do: :warning
  defp severity_to_level(:notice), do: :info
  defp severity_to_level(:info), do: :info
  defp severity_to_level(:debug), do: :debug
  defp severity_to_level(_), do: :info
end
