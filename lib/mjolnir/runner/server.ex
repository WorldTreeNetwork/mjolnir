defmodule Mjolnir.Runner.Server do
  @moduledoc """
  OTP-managed Forgejo runner process.

  The runner binary runs as an Erlang Port under this GenServer — no systemd
  unit required. On boot the server resolves config, writes the runner YAML,
  ensures the state directory exists, and spawns the binary as a Port.

  ## Lifecycle

  - If `runner_enabled` is false (the default), `init/1` returns immediately
    with `status: :disabled` and does nothing. Safe for dev/test environments
    where the binary does not exist.
  - If the binary is missing, `init/1` logs a warning and enters
    `status: :disabled` rather than crashing the supervision tree.
  - On exit, the GenServer schedules a restart with exponential backoff
    (1s initial, 30s max) rather than crashing its supervisor.
  - `terminate/2` sends SIGTERM and waits up to 5s, then SIGKILL.

  ## Config

  See `Mjolnir.Runner.Config`. Set `runner_enabled: true` (or env
  `MJOLNIR_RUNNER_ENABLED=true`) to activate.
  """

  use GenServer
  require Logger

  alias Mjolnir.Runner.Config
  alias Mjolnir.Runner.ConfigWriter

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns :running, :disabled, or :restarting."
  @spec status() :: :running | :disabled | :restarting
  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> :disabled
      _ -> GenServer.call(__MODULE__, :status)
    end
  end

  @doc "Gracefully stop the runner (SIGTERM)."
  @spec stop() :: :ok
  def stop do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _ -> GenServer.stop(__MODULE__, :normal)
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    config = Config.resolve()

    if config.enabled do
      start_runner(config)
    else
      Logger.info("Runner.Server: runner_enabled=false; runner will not start")
      {:ok, %{status: :disabled, config: config, port: nil, os_pid: nil, backoff_ms: @initial_backoff_ms}}
    end
  end

  @impl true
  def handle_call(:status, _from, %{status: status} = state) do
    {:reply, status, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    log_runner_output(data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("Runner.Server: runner process exited code=#{code}; restarting in #{state.backoff_ms}ms")
    Process.send_after(self(), :restart, state.backoff_ms)
    new_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
    {:noreply, %{state | port: nil, os_pid: nil, status: :restarting, backoff_ms: new_backoff}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("Runner.Server: port EXIT reason=#{inspect(reason)}; restarting in #{state.backoff_ms}ms")
    Process.send_after(self(), :restart, state.backoff_ms)
    new_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
    {:noreply, %{state | port: nil, os_pid: nil, status: :restarting, backoff_ms: new_backoff}}
  end

  def handle_info(:restart, state) do
    Logger.info("Runner.Server: attempting restart")

    case spawn_port(state.config) do
      {:ok, port, pid} ->
        Logger.info("Runner.Server: runner restarted os_pid=#{pid}")
        {:noreply, %{state | port: port, os_pid: pid, status: :running, backoff_ms: @initial_backoff_ms}}

      {:error, reason} ->
        Logger.warning("Runner.Server: restart failed (#{inspect(reason)}); retrying in #{state.backoff_ms}ms")
        Process.send_after(self(), :restart, state.backoff_ms)
        new_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
        {:noreply, %{state | backoff_ms: new_backoff}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(reason, %{os_pid: pid, port: port}) when is_integer(pid) do
    Logger.info("Runner.Server: terminating reason=#{inspect(reason)}; SIGTERM runner pid=#{pid}")
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

    if not wait_pid_gone(pid, 5_000) do
      Logger.warning("Runner.Server: runner pid=#{pid} did not exit; SIGKILL")
      _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internal

  defp start_runner(config) do
    case check_binary(config) do
      :ok ->
        case setup_and_spawn(config) do
          {:ok, port, pid} ->
            Logger.info("Runner.Server: runner started os_pid=#{pid} binary=#{config.binary_path}")
            {:ok, %{status: :running, config: config, port: port, os_pid: pid, backoff_ms: @initial_backoff_ms}}

          {:error, reason} ->
            Logger.error("Runner.Server: failed to start runner (#{inspect(reason)})")
            {:stop, {:runner_start_failed, reason}}
        end

      {:error, reason} ->
        Logger.warning("Runner.Server: #{reason}; running in disabled state")
        {:ok, %{status: :disabled, config: config, port: nil, os_pid: nil, backoff_ms: @initial_backoff_ms}}
    end
  end

  defp check_binary(config) do
    cond do
      not File.exists?(config.binary_path) ->
        {:error, "binary not found at #{config.binary_path}"}

      not executable?(config.binary_path) ->
        {:error, "binary at #{config.binary_path} is not executable"}

      true ->
        :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp setup_and_spawn(config) do
    with :ok <- ConfigWriter.write_config(config) do
      spawn_port(config)
    end
  end

  defp spawn_port(config) do
    port =
      Port.open(
        {:spawn_executable, config.binary_path},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: ["daemon", "--config", config.config_path],
          env: [{'GITEA_INSTANCE_URL', String.to_charlist(config.forgejo_url)}]
        ]
      )

    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, port, pid}
      nil -> {:error, :port_open_failed}
    end
  rescue
    e -> {:error, e}
  end

  defp wait_pid_gone(pid, timeout) do
    deadline = monotonic_ms() + timeout
    do_wait_pid_gone(pid, deadline)
  end

  defp do_wait_pid_gone(pid, deadline) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        if monotonic_ms() < deadline do
          Process.sleep(100)
          do_wait_pid_gone(pid, deadline)
        else
          false
        end

      _ ->
        true
    end
  end

  defp log_runner_output(data) do
    data
    |> String.split("\n")
    |> Enum.each(fn line ->
      trimmed = String.trim_trailing(line)
      if trimmed != "", do: Logger.info("[runner] #{trimmed}")
    end)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
