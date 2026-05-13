defmodule Mjolnir.Postgres.Bootstrap do
  @moduledoc """
  Idempotent role / database / schema / grant bootstrap. Runs after
  `Mjolnir.Postgres.Server` reports ready.

  The model:

  * `mjolnir_admin` is the owner role. `initdb` already created it (Server runs
    `initdb --username=<bootstrap_role>`). It owns the database, all schemas,
    and all migrations.
  * Service roles (`mjolnir_sites`, …) are LOGIN roles with narrow grants on
    their own schema. They are granted CRUD on **future** tables created by
    `mjolnir_admin` via `ALTER DEFAULT PRIVILEGES`, so a normal migration run
    automatically gives the service role access to what it needs.
  * All connections are peer-authenticated over the Unix socket. The OS user
    that runs the BEAM is mapped in `pg_ident.conf` to every role listed in
    `pg_ident_users` × `pg_roles`, so a single BEAM can present itself as
    either `mjolnir_admin` (for migrations) or `mjolnir_sites` (for app
    queries) by setting the connection's `username:` field.

  Children supervised by `Mjolnir.Postgres.Supervisor` run this once on app
  boot. The boot crash on failure — corrupt bootstrap state means the app
  cannot serve queries.
  """

  use GenServer
  require Logger

  alias Mjolnir.Postgres.Config

  @ident_re ~r/^[a-z_][a-z0-9_]*$/

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "True after the bootstrap has completed in this OS process."
  @spec done?() :: boolean()
  def done? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :done?)
    end
  end

  @doc """
  Run the bootstrap directly (without a GenServer). Useful for tests that
  bring up their own Postgres instance. Returns `:ok` or `{:error, reason}`.
  """
  @spec run(Config.t()) :: :ok | {:error, term()}
  def run(%Config{} = config) do
    with :ok <- ensure_roles(config),
         :ok <- ensure_database(config),
         :ok <- ensure_schemas_and_grants(config) do
      :ok
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    config = Config.resolve()

    if config.managed do
      case run(config) do
        :ok ->
          Logger.info("Postgres.Bootstrap: roles + schemas ready")
          {:ok, %{config: config, done: true}}

        {:error, reason} = err ->
          Logger.error("Postgres.Bootstrap: failed (#{inspect(reason)})")
          {:stop, err}
      end
    else
      Logger.info("Postgres.Bootstrap: skipped (managed=false)")
      {:ok, %{config: config, done: false}}
    end
  end

  @impl true
  def handle_call(:done?, _from, %{done: done} = state) do
    {:reply, done, state}
  end

  ## Internals

  defp ensure_roles(config) do
    with_admin_conn(config, "postgres", fn conn ->
      Enum.reduce_while(config.roles, :ok, fn role, _ ->
        validate_ident!(role)

        case role == config.bootstrap_role do
          true ->
            # bootstrap role exists by virtue of initdb --username; nothing to
            # do, but make sure it can log in (initdb creates it with LOGIN).
            {:cont, :ok}

          false ->
            sql = """
            DO $$
            BEGIN
              IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
                CREATE ROLE "#{role}" LOGIN;
              END IF;
            END
            $$;
            """

            case Postgrex.query(conn, sql, []) do
              {:ok, _} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:create_role, role, reason}}}
            end
        end
      end)
    end)
  end

  defp ensure_database(config) do
    with_admin_conn(config, "postgres", fn conn ->
      validate_ident!(config.db_name)
      validate_ident!(config.bootstrap_role)

      case Postgrex.query(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [config.db_name]) do
        {:ok, %{num_rows: 0}} ->
          # CREATE DATABASE cannot run inside a transaction; Postgrex queries
          # are autocommit by default so this works.
          sql = ~s|CREATE DATABASE "#{config.db_name}" OWNER "#{config.bootstrap_role}"|

          case Postgrex.query(conn, sql, []) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, {:create_database, reason}}
          end

        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, {:check_database, reason}}
      end
    end)
  end

  defp ensure_schemas_and_grants(config) do
    with_admin_conn(config, config.db_name, fn conn ->
      # Service-role → schema mapping. Bootstrap role gets no schema (it's the
      # owner; it already has everything).
      service_grants =
        for role <- config.roles, role != config.bootstrap_role do
          {role, role_schema(role)}
        end

      Enum.reduce_while(service_grants, :ok, fn {role, schema}, _ ->
        validate_ident!(role)
        validate_ident!(schema)

        statements = [
          ~s|CREATE SCHEMA IF NOT EXISTS "#{schema}" AUTHORIZATION "#{config.bootstrap_role}"|,
          ~s|GRANT CONNECT ON DATABASE "#{config.db_name}" TO "#{role}"|,
          ~s|GRANT USAGE ON SCHEMA "#{schema}" TO "#{role}"|,
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "#{schema}" TO "#{role}"|,
          ~s|GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA "#{schema}" TO "#{role}"|,
          ~s|ALTER DEFAULT PRIVILEGES FOR ROLE "#{config.bootstrap_role}" IN SCHEMA "#{schema}" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "#{role}"|,
          ~s|ALTER DEFAULT PRIVILEGES FOR ROLE "#{config.bootstrap_role}" IN SCHEMA "#{schema}" GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "#{role}"|
        ]

        case run_statements(conn, statements) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end)
  end

  defp run_statements(conn, statements) do
    Enum.reduce_while(statements, :ok, fn sql, _ ->
      case Postgrex.query(conn, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:ddl, sql, reason}}}
      end
    end)
  end

  defp with_admin_conn(config, database, fun) do
    opts = [
      socket_dir: config.socket_dir,
      username: config.bootstrap_role,
      database: database,
      backoff_type: :stop,
      pool_size: 1,
      idle_interval: 5_000
    ]

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        rescue
          e -> {:error, {:bootstrap_exception, e}}
        after
          GenServer.stop(conn, :normal, 5_000)
        end

      {:error, reason} ->
        {:error, {:connect, database, reason}}
    end
  end

  # Convention: each service role gets a schema with the same name minus the
  # "mjolnir_" prefix. `mjolnir_sites` → `sites`, `mjolnir_secrets` → `secrets`.
  defp role_schema("mjolnir_" <> rest), do: rest
  defp role_schema(other), do: other

  defp validate_ident!(s) when is_binary(s) do
    if Regex.match?(@ident_re, s) do
      s
    else
      raise ArgumentError, "invalid postgres identifier: #{inspect(s)}"
    end
  end
end
