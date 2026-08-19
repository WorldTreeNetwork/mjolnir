defmodule Mjolnir.Postgres.Server do
  @moduledoc """
  OTP-managed Postgres instance for the Mjolnir sidecar.

  Postgres runs as an Erlang Port under this GenServer — no systemd unit, no
  pg_ctl daemon. On boot the server prepares the data directory (initdb on
  first run), refreshes `postgresql.conf` / `pg_hba.conf` / `pg_ident.conf`,
  spawns `postgres -D <data_dir>`, and waits until the Unix socket is
  accepting connections.

  Connections from Elixir use peer-authentication over the Unix socket — see
  `Mjolnir.Postgres.Bootstrap` for the role/ident map design.

  ## Lifecycle

  - `init/1` is synchronous: it blocks until either the socket is ready or
    the startup deadline elapses. Failures stop the GenServer (`{:stop, ...}`)
    so its supervisor can decide whether to crash the app.
  - The Postgres process is owned by the Port; if it exits, the GenServer
    crashes and its supervisor restarts the whole thing.
  - `terminate/2` sends SIGTERM to the OS pid and waits up to 10s for clean
    shutdown.

  ## Config

  See `Mjolnir.Postgres.Config`. Set `pg_managed: false` to run Mjolnir
  against an externally-managed Postgres (the Server still tracks readiness
  but does not spawn anything).
  """

  use GenServer
  require Logger

  alias Mjolnir.Postgres.Config

  @startup_timeout 30_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Resolved socket path the BEAM should connect to."
  @spec socket_path() :: String.t()
  def socket_path, do: Config.resolve().socket_path

  @doc "Resolved socket directory (the value passed to `host=` for libpq)."
  @spec socket_dir() :: String.t()
  def socket_dir, do: Config.resolve().socket_dir

  @doc "True if Postgres is reachable via the socket."
  @spec ready?() :: boolean()
  def ready? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      _ -> GenServer.call(__MODULE__, :ready?)
    end
  end

  @doc "Block (up to `timeout` ms) until Postgres reports ready."
  @spec await_ready(non_neg_integer()) :: :ok | {:error, :timeout}
  def await_ready(timeout \\ @startup_timeout) do
    deadline = monotonic_ms() + timeout
    do_await_ready(deadline)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    config = Config.resolve()

    if config.managed do
      start_managed(config)
    else
      Logger.info(
        "Postgres.Server: managed=false; expecting external pg at #{config.socket_path}"
      )

      {:ok, %{config: config, port: nil, os_pid: nil}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, pg_isready(state.config), state}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Postgres.Server: postgres process exited code=#{code}")
    {:stop, {:postgres_exited, code}, %{state | port: nil}}
  end

  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state) do
    log_pg_line(line)
    {:noreply, state}
  end

  def handle_info({port, {:data, line}}, %{port: port} = state) when is_binary(line) do
    log_pg_line(line)
    {:noreply, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("Postgres.Server: port EXIT reason=#{inspect(reason)}")
    {:stop, {:port_exit, reason}, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(reason, %{config: config, os_pid: pid, port: port}) when is_integer(pid) do
    Logger.info("Postgres.Server: terminating reason=#{inspect(reason)}; SIGTERM pg pid=#{pid}")
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

    if not wait_pid_gone(pid, 10_000) do
      Logger.warning("Postgres.Server: pg pid=#{pid} did not exit; SIGKILL")
      _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    _ = config
    :ok
  end

  ## Internal — managed startup

  defp start_managed(config) do
    with :ok <- check_binaries(config),
         :ok <- maybe_assign_tenant_listen(config),
         :ok <- check_tenant_listen(config),
         :ok <- ensure_dirs(config),
         :ok <- maybe_initdb(config),
         :ok <- write_conf_files(config),
         {:ok, port, pid} <- spawn_postgres(config),
         :ok <- wait_ready(config, port) do
      Logger.info("Postgres.Server: ready socket=#{config.socket_path} os_pid=#{pid}")
      {:ok, %{config: config, port: port, os_pid: pid}}
    else
      {:error, reason} ->
        Logger.error("Postgres.Server: failed to start (#{inspect(reason)})")
        {:stop, {:postgres_start_failed, reason}}
    end
  end

  defp maybe_assign_tenant_listen(%Config{tenant_listen_ip: nil}), do: :ok

  defp maybe_assign_tenant_listen(%Config{tenant_listen_ip: _ip}) do
    Mjolnir.Network.ensure_host_api_addr()
  end

  defp check_tenant_listen(%Config{tenant_listen_ip: nil}), do: :ok

  defp check_tenant_listen(%Config{tenant_listen_ip: ip}) do
    if Mjolnir.Network.ip_assigned?(ip) do
      :ok
    else
      {:error, {:tenant_listen_ip_missing, ip}}
    end
  end

  defp check_binaries(config) do
    Enum.reduce_while(
      [
        {"postgres", config.postgres_bin},
        {"initdb", config.initdb_bin},
        {"pg_isready", config.pg_isready_bin}
      ],
      :ok,
      fn {name, path}, _ ->
        if File.regular?(path) and File.stat!(path).mode |> Bitwise.band(0o111) != 0 do
          {:cont, :ok}
        else
          {:halt, {:error, {:missing_binary, name, path}}}
        end
      end
    )
  end

  defp ensure_dirs(config) do
    with :ok <- File.mkdir_p(config.data_dir),
         :ok <- File.mkdir_p(config.socket_dir),
         :ok <- File.mkdir_p(config.log_dir) do
      if config.run_as do
        # Make sure the OS user that will run postgres owns its dirs.
        chown_paths([config.data_dir, config.socket_dir, config.log_dir], config.run_as)
      else
        :ok
      end
    end
  end

  defp chown_paths(paths, user) do
    case Enum.reduce_while(paths, :ok, fn p, _ ->
           case System.cmd("chown", ["-R", "#{user}:#{user}", p], stderr_to_stdout: true) do
             {_, 0} -> {:cont, :ok}
             {out, code} -> {:halt, {:error, {:chown_failed, p, code, String.trim(out)}}}
           end
         end) do
      :ok -> :ok
      err -> err
    end
  end

  defp maybe_initdb(config) do
    if File.regular?(Path.join(config.data_dir, "PG_VERSION")) do
      :ok
    else
      run_initdb(config)
    end
  end

  defp run_initdb(config) do
    Logger.info("Postgres.Server: running initdb in #{config.data_dir}")

    args = [
      "--pgdata=#{config.data_dir}",
      "--username=#{config.bootstrap_role}",
      "--auth-local=peer",
      "--auth-host=reject",
      "--encoding=UTF8",
      "--locale=C",
      "--no-sync"
    ]

    {cmd, full_args} = maybe_wrap_setpriv(config, config.initdb_bin, args)

    case System.cmd(cmd, full_args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        {:error, {:initdb_failed, code, String.trim(out)}}
    end
  end

  defp write_conf_files(config) do
    with :ok <-
           File.write(Path.join(config.data_dir, "postgresql.conf"), postgresql_conf(config)),
         :ok <- File.write(Path.join(config.data_dir, "pg_hba.conf"), pg_hba_conf(config)),
         :ok <- File.write(Path.join(config.data_dir, "pg_ident.conf"), pg_ident_conf(config)) do
      if config.run_as do
        chown_paths([config.data_dir], config.run_as)
      else
        :ok
      end
    end
  end

  defp postgresql_conf(config) do
    listen =
      case config.tenant_listen_ip do
        nil -> "''"
        ip -> "'#{ip}'"
      end

    """
    # Managed by Mjolnir.Postgres.Server — overwritten on every boot.
    listen_addresses = #{listen}
    unix_socket_directories = '#{config.socket_dir}'
    unix_socket_permissions = 0770
    max_connections = 100
    shared_buffers = 128MB
    dynamic_shared_memory_type = posix
    password_encryption = scram-sha-256
    log_destination = 'stderr'
    logging_collector = off
    log_min_messages = warning
    log_min_error_statement = error
    log_line_prefix = '%m [%p] %q%u@%d '
    timezone = 'UTC'
    log_timezone = 'UTC'
    datestyle = 'iso, mdy'
    default_text_search_config = 'pg_catalog.english'
    """
  end

  defp pg_hba_conf(config) do
    tenant_lines =
      config
      |> Mjolnir.Postgres.Tenants.list()
      |> Enum.map(fn %{name: name} ->
        "host #{name} #{name} #{Mjolnir.Network.network_range()} scram-sha-256\n"
      end)
      |> IO.iodata_to_binary()

    """
    # Managed by Mjolnir.Postgres.Server — overwritten on every boot.
    # Unix-socket peer for the BEAM. Tenant TCP is overlay CIDR only.
    local all all peer map=mjolnir_map
    #{tenant_lines}
    """
  end

  defp pg_ident_conf(config) do
    header = "# Managed by Mjolnir.Postgres.Server — overwritten on every boot.\n"

    body =
      for os_user <- config.ident_users,
          role <- config.roles do
        "mjolnir_map\t#{os_user}\t#{role}\n"
      end
      |> IO.iodata_to_binary()

    header <> body
  end

  defp spawn_postgres(config) do
    {cmd, args} =
      maybe_wrap_setpriv(config, config.postgres_bin, ["-D", config.data_dir])

    case System.find_executable(cmd) do
      nil ->
        {:error, {:no_executable, cmd}}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [:exit_status, :stderr_to_stdout, {:args, args}, :binary, {:line, 4096}]
          )

        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> {:ok, port, pid}
          nil -> {:error, :port_open_failed}
        end
    end
  end

  defp maybe_wrap_setpriv(%Config{run_as: nil}, bin, args), do: {bin, args}

  defp maybe_wrap_setpriv(%Config{run_as: user}, bin, args) do
    {"setpriv", ["--reuid=#{user}", "--regid=#{user}", "--init-groups", "--", bin | args]}
  end

  defp wait_ready(config, port) do
    deadline = monotonic_ms() + @startup_timeout
    do_wait_ready(config, port, deadline)
  end

  defp do_wait_ready(config, port, deadline) do
    cond do
      not is_port_alive?(port) ->
        drain_port(port)
        {:error, :postgres_exited_during_startup}

      pg_isready(config) ->
        :ok

      monotonic_ms() > deadline ->
        {:error, :startup_timeout}

      true ->
        Process.sleep(100)
        do_wait_ready(config, port, deadline)
    end
  end

  defp is_port_alive?(port), do: Port.info(port) != nil

  defp drain_port(port) do
    receive do
      {^port, {:data, {_eol, line}}} ->
        log_pg_line(line)
        drain_port(port)

      {^port, {:data, line}} when is_binary(line) ->
        log_pg_line(line)
        drain_port(port)

      {^port, {:exit_status, code}} ->
        Logger.error("Postgres.Server: postgres exited during startup code=#{code}")
    after
      0 -> :ok
    end
  end

  defp pg_isready(config) do
    # Explicit user/db prevent libpq from defaulting to the OS user, which is
    # not in pg_ident.conf and causes a FATAL peer-auth log line on every
    # readiness probe. pg_isready treats auth failures as "server is up",
    # so the previous form worked — it just spammed the log.
    case System.cmd(
           config.pg_isready_bin,
           [
             "-h",
             config.socket_dir,
             "-U",
             config.bootstrap_role,
             "-d",
             config.db_name,
             "-q"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp do_await_ready(deadline) do
    if ready?() do
      :ok
    else
      if monotonic_ms() < deadline do
        Process.sleep(50)
        do_await_ready(deadline)
      else
        {:error, :timeout}
      end
    end
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

  @doc """
  Rewrite `pg_hba.conf` from the tenant registry and `pg_reload_conf()`.
  Called after `Tenants.ensure/2`.
  """
  @spec reload_hba() :: :ok | {:error, term()}
  def reload_hba do
    config = Config.resolve()
    path = Path.join(config.data_dir, "pg_hba.conf")

    with :ok <- File.write(path, pg_hba_conf(config)),
         {:ok, conn} <-
           Postgrex.start_link(
             socket_dir: config.socket_dir,
             username: config.bootstrap_role,
             database: config.db_name,
             backoff_type: :stop,
             pool_size: 1
           ) do
      try do
        case Postgrex.query(conn, "SELECT pg_reload_conf()", []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:reload_conf, reason}}
        end
      after
        GenServer.stop(conn, :normal, 5_000)
      end
    end
  end

  defp log_pg_line(line) do
    trimmed = String.trim_trailing(line)
    if trimmed != "", do: Logger.info("postgres: #{trimmed}")
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
