defmodule Mjolnir.Syslog.Router do
  @moduledoc """
  Routes parsed syslog messages to configured sinks.

  Two EventBus types share this router:

  - `:vm_syslog` — RFC 3164 guest/host text (default sinks `[:eventbus, :logger]`)
  - `:app_log` — MSG is a JSON object with `schema` (default sinks `[:eventbus]`
    only; an app debug stream must not double into journald)

  ## Sinks

  - `:eventbus` — `EventBus.publish(id, type, payload)`
  - `:logger`   — Elixir Logger with VM/app metadata attached

  ## Configuration

      config :mjolnir, :syslog,
        sinks: [:eventbus, :logger],
        app_log_sinks: [:eventbus]
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
  def route(vm_id, cid, %Message{} = message) when is_binary(vm_id) do
    GenServer.cast(__MODULE__, {:route, vm_id, cid, message})
  end

  @doc """
  Route a typed app log record. `app_id` is self-asserted (UDP has no peer
  credentials). Default sink is EventBus only.
  """
  @spec route_app_log(String.t(), map()) :: :ok
  def route_app_log(app_id, record) when is_binary(app_id) and is_map(record) do
    GenServer.cast(__MODULE__, {:route_app_log, app_id, record})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:mjolnir, :syslog, [])

    {:ok,
     %{
       sinks: Keyword.get(cfg, :sinks, [:eventbus, :logger]),
       app_log_sinks: Keyword.get(cfg, :app_log_sinks, [:eventbus])
     }}
  end

  @impl true
  def handle_cast({:route, vm_id, _cid, message}, state) do
    Enum.each(state.sinks, fn sink -> dispatch(sink, vm_id, message) end)
    {:noreply, state}
  end

  def handle_cast({:route_app_log, app_id, record}, state) do
    Enum.each(state.app_log_sinks, fn sink -> dispatch_app(sink, app_id, record) end)
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

  defp dispatch_app(:eventbus, app_id, record) do
    Mjolnir.EventBus.publish(app_id, :app_log, record)
  end

  defp dispatch_app(:logger, app_id, record) do
    level = pino_level_to_logger(record["level"])
    text = record["msg"] || safe_encode(record)

    Logger.log(level, "[app=#{app_id}] #{text}",
      app_id: app_id,
      log_schema: record["schema"]
    )
  end

  defp dispatch_app(unknown, _app_id, _record) do
    Logger.warning("Syslog.Router: unknown app_log sink #{inspect(unknown)}")
  end

  # pino: 10 trace, 20 debug, 30 info, 40 warn, 50 error, 60 fatal
  defp pino_level_to_logger(level) when is_integer(level) and level >= 50, do: :error
  defp pino_level_to_logger(level) when is_integer(level) and level >= 40, do: :warning
  defp pino_level_to_logger(level) when is_integer(level) and level >= 30, do: :info
  defp pino_level_to_logger(level) when is_integer(level), do: :debug
  defp pino_level_to_logger(_), do: :info

  defp safe_encode(record) do
    case Jason.encode(record) do
      {:ok, json} -> json
      _ -> inspect(record)
    end
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
