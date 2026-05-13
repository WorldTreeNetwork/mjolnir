defmodule Mjolnir.Postgres.BootstrapTest do
  @moduledoc """
  Integration test for `Mjolnir.Postgres.Bootstrap`. Brings up a fresh
  Postgres via `Mjolnir.Postgres.Server`, runs the bootstrap, then verifies
  roles, database, schema, and grants by reading the system catalogs.
  """

  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Postgres.{Bootstrap, Config, Server}

  setup do
    base = Path.join(System.tmp_dir!(), "mjolnir-pg-boot-#{:erlang.unique_integer([:positive])}")
    data_dir = Path.join(base, "data")
    socket_dir = Path.join(base, "sock")
    log_dir = Path.join(base, "log")
    File.mkdir_p!(socket_dir)
    File.mkdir_p!(log_dir)

    prev = capture_env()

    Application.put_env(:mjolnir, :pg_managed, true)
    Application.put_env(:mjolnir, :pg_data_dir, data_dir)
    Application.put_env(:mjolnir, :pg_socket_dir, socket_dir)
    Application.put_env(:mjolnir, :pg_log_dir, log_dir)
    Application.put_env(:mjolnir, :pg_bin_dir, find_bin_dir())
    Application.put_env(:mjolnir, :pg_run_as, nil)
    Application.put_env(:mjolnir, :pg_bootstrap_role, "mjolnir_admin")
    Application.put_env(:mjolnir, :pg_roles, ["mjolnir_admin", "mjolnir_sites"])
    Application.put_env(:mjolnir, :pg_ident_users, [System.get_env("USER")])
    Application.put_env(:mjolnir, :pg_database, "mjolnir")

    {:ok, server_pid} = Server.start_link([])
    :ok = Server.await_ready(15_000)

    on_exit(fn ->
      try do
        if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 15_000)
      catch
        :exit, _ -> :ok
      end

      restore_env(prev)
      File.rm_rf!(base)
    end)

    {:ok, config: Config.resolve(), socket_dir: socket_dir}
  end

  test "creates service role, database, schema, and default-privilege grants", ctx do
    assert :ok = Bootstrap.run(ctx.config)

    # Roles exist
    assert query_one(ctx, "postgres", "SELECT 1 FROM pg_roles WHERE rolname = 'mjolnir_sites'")
    assert query_one(ctx, "postgres", "SELECT 1 FROM pg_roles WHERE rolname = 'mjolnir_admin'")

    # Database exists with correct owner
    [[db_owner]] =
      query_rows(ctx, "postgres", """
      SELECT r.rolname
      FROM pg_database d JOIN pg_roles r ON d.datdba = r.oid
      WHERE d.datname = 'mjolnir'
      """)

    assert db_owner == "mjolnir_admin"

    # Schema exists in target db with correct owner
    [[schema_owner]] =
      query_rows(ctx, "mjolnir", """
      SELECT r.rolname FROM pg_namespace n JOIN pg_roles r ON n.nspowner = r.oid
      WHERE n.nspname = 'sites'
      """)

    assert schema_owner == "mjolnir_admin"

    # mjolnir_sites has USAGE on sites schema
    [[usage]] =
      query_rows(ctx, "mjolnir", """
      SELECT has_schema_privilege('mjolnir_sites', 'sites', 'USAGE')
      """)

    assert usage == true

    # Default privileges are configured for future tables (verify via catalog)
    default_privs =
      query_rows(ctx, "mjolnir", """
      SELECT defaclacl::text
      FROM pg_default_acl d JOIN pg_namespace n ON d.defaclnamespace = n.oid
      WHERE n.nspname = 'sites' AND d.defaclobjtype = 'r'
      """)

    assert length(default_privs) == 1
    [[acl_text]] = default_privs
    assert String.contains?(acl_text, "mjolnir_sites=arwd")
  end

  test "second run is idempotent (no errors, no duplicate state)", ctx do
    assert :ok = Bootstrap.run(ctx.config)
    assert :ok = Bootstrap.run(ctx.config)
    assert :ok = Bootstrap.run(ctx.config)

    # Still exactly one of each
    [[role_count]] =
      query_rows(ctx, "postgres", "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'mjolnir_sites'")

    assert role_count == 1

    [[db_count]] =
      query_rows(ctx, "postgres", "SELECT COUNT(*) FROM pg_database WHERE datname = 'mjolnir'")

    assert db_count == 1

    [[schema_count]] =
      query_rows(ctx, "mjolnir", "SELECT COUNT(*) FROM pg_namespace WHERE nspname = 'sites'")

    assert schema_count == 1
  end

  test "mjolnir_sites cannot create a table in the public schema (least-privilege check)", ctx do
    assert :ok = Bootstrap.run(ctx.config)

    {:ok, conn} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_sites",
        database: "mjolnir",
        backoff_type: :stop
      )

    # By default Postgres 15+ removes public-schema CREATE for non-owners, so
    # this should be denied.
    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(conn, "CREATE TABLE public.attacker(id int)", [])

    GenServer.stop(conn, :normal, 5_000)
  end

  test "mjolnir_admin can create tables in sites schema, and mjolnir_sites can RW them", ctx do
    assert :ok = Bootstrap.run(ctx.config)

    # Create as admin
    {:ok, admin} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: "mjolnir",
        backoff_type: :stop
      )

    Postgrex.query!(admin, "CREATE TABLE sites.demo (id int PRIMARY KEY, val text)", [])
    GenServer.stop(admin, :normal, 5_000)

    # Read/write as service role
    {:ok, app} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_sites",
        database: "mjolnir",
        backoff_type: :stop
      )

    assert {:ok, _} = Postgrex.query(app, "INSERT INTO sites.demo VALUES (1, 'hello')", [])
    assert %{rows: [[1, "hello"]]} = Postgrex.query!(app, "SELECT id, val FROM sites.demo", [])

    GenServer.stop(app, :normal, 5_000)
  end

  ## Helpers

  defp query_rows(ctx, db, sql) do
    {:ok, conn} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: db,
        backoff_type: :stop
      )

    result = Postgrex.query!(conn, sql, [])
    GenServer.stop(conn, :normal, 5_000)
    result.rows
  end

  defp query_one(ctx, db, sql) do
    case query_rows(ctx, db, sql) do
      [_ | _] -> true
      _ -> false
    end
  end

  defp find_bin_dir do
    cond do
      File.regular?("/usr/bin/postgres") -> "/usr/bin"
      File.regular?("/usr/local/bin/postgres") -> "/usr/local/bin"
      true -> "/usr/bin"
    end
  end

  defp capture_env do
    keys = [
      :pg_managed,
      :pg_data_dir,
      :pg_socket_dir,
      :pg_log_dir,
      :pg_bin_dir,
      :pg_run_as,
      :pg_bootstrap_role,
      :pg_roles,
      :pg_ident_users,
      :pg_database
    ]

    for k <- keys, into: %{}, do: {k, Application.get_env(:mjolnir, k)}
  end

  defp restore_env(prev) do
    for {k, v} <- prev do
      case v do
        nil -> Application.delete_env(:mjolnir, k)
        v -> Application.put_env(:mjolnir, k, v)
      end
    end
  end
end
