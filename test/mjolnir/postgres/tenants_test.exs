defmodule Mjolnir.Postgres.TenantsTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Postgres.{Bootstrap, Config, Server, Tenants}

  setup do
    base = Path.join(System.tmp_dir!(), "mjolnir-pg-ten-#{:erlang.unique_integer([:positive])}")
    data_dir = Path.join(base, "data")
    socket_dir = Path.join(base, "sock")
    log_dir = Path.join(base, "log")
    secrets_dir = Path.join(base, "secrets")
    tenants_file = Path.join(base, "tenants.json")

    File.mkdir_p!(socket_dir)
    File.mkdir_p!(log_dir)
    File.mkdir_p!(secrets_dir)

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
    Application.put_env(:mjolnir, :pg_tenant_listen_ip, nil)
    Application.put_env(:mjolnir, :pg_tenants_file, tenants_file)
    Application.put_env(:mjolnir, :deploy_secrets_dir, secrets_dir)

    {:ok, server_pid} = Server.start_link([])
    :ok = Server.await_ready(15_000)
    config = Config.resolve()
    assert :ok = Bootstrap.run(config)

    on_exit(fn ->
      try do
        if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 15_000)
      catch
        :exit, _ -> :ok
      end

      restore_env(prev)
      File.rm_rf!(base)
    end)

    {:ok,
     config: config,
     socket_dir: socket_dir,
     secrets_dir: secrets_dir,
     tenants_file: tenants_file,
     data_dir: data_dir}
  end

  test "ensure creates role, database, escrow URL, and is idempotent", ctx do
    assert {:ok, %{name: "hypersigil", slug: "hypersigil-api"}} =
             Tenants.ensure("hypersigil", slug: "hypersigil-api")

    assert {:ok, _} = Tenants.ensure("hypersigil", slug: "hypersigil-api")

    assert query_one(ctx, "postgres", "SELECT 1 FROM pg_roles WHERE rolname = 'hypersigil'")
    assert query_one(ctx, "postgres", "SELECT 1 FROM pg_database WHERE datname = 'hypersigil'")

    [[owner]] =
      query_rows(ctx, "postgres", """
      SELECT r.rolname FROM pg_database d JOIN pg_roles r ON d.datdba = r.oid
      WHERE d.datname = 'hypersigil'
      """)

    assert owner == "hypersigil"

    path = Path.join(ctx.secrets_dir, "hypersigil-api.json")
    assert File.regular?(path)
    %{"DATABASE_URL" => url} = Jason.decode!(File.read!(path))
    assert url =~ ~r{^postgres://hypersigil:[^@]+@10\.200\.0\.1:5432/hypersigil$}

    assert %{name: "hypersigil", slug: "hypersigil-api"} in Tenants.list()

    ident = File.read!(Path.join(ctx.data_dir, "pg_ident.conf"))
    refute ident =~ "hypersigil"

    hba = File.read!(Path.join(ctx.data_dir, "pg_hba.conf"))
    assert hba =~ "host hypersigil hypersigil 10.200.0.0/10 scram-sha-256"
    refute hba =~ "host all all"
  end

  test "tenant owns DDL on its database and cannot CONNECT to mjolnir", ctx do
    assert {:ok, _} = Tenants.ensure("hypersigil", slug: "hypersigil-api")

    [[can_create]] =
      query_rows(
        ctx,
        "postgres",
        "SELECT has_database_privilege('hypersigil', 'hypersigil', 'CREATE')"
      )

    assert can_create == true

    [[can_connect_home]] =
      query_rows(
        ctx,
        "postgres",
        "SELECT has_database_privilege('hypersigil', 'mjolnir', 'CONNECT')"
      )

    assert can_connect_home == false
  end

  test "PUBLIC cannot walk the hotel across two tenants", ctx do
    assert {:ok, _} = Tenants.ensure("hypersigil", slug: "hypersigil-api")
    assert {:ok, _} = Tenants.ensure("other", slug: "other")

    [[walk]] =
      query_rows(
        ctx,
        "postgres",
        "SELECT has_database_privilege('hypersigil', 'other', 'CONNECT')"
      )

    assert walk == false
  end

  test "second ensure does not drop catalog tables", ctx do
    assert {:ok, _} = Tenants.ensure("hypersigil", slug: "hypersigil-api")

    {:ok, admin} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: "hypersigil",
        backoff_type: :stop
      )

    Postgrex.query!(admin, "CREATE TABLE keepme (id int PRIMARY KEY)", [])
    Postgrex.query!(admin, "INSERT INTO keepme VALUES (1)", [])
    GenServer.stop(admin, :normal, 5_000)

    assert {:ok, _} = Tenants.ensure("hypersigil", slug: "hypersigil-api")

    {:ok, admin2} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: "hypersigil",
        backoff_type: :stop
      )

    %{rows: [[1]]} = Postgrex.query!(admin2, "SELECT id FROM keepme", [])
    GenServer.stop(admin2, :normal, 5_000)
  end

  test "rejects invalid ident" do
    assert {:error, {:invalid_ident, _}} = Tenants.ensure("Hypersigil")
    assert {:error, {:invalid_ident, _}} = Tenants.ensure("drop-me")
  end

  ## Helpers

  defp query_one(ctx, db, sql) do
    case query_rows(ctx, db, sql) do
      [[_ | _] | _] -> true
      _ -> false
    end
  end

  defp query_rows(ctx, db, sql) do
    {:ok, conn} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: db,
        backoff_type: :stop
      )

    %{rows: rows} = Postgrex.query!(conn, sql, [])
    GenServer.stop(conn, :normal, 5_000)
    rows
  end

  defp find_bin_dir do
    cond do
      File.regular?("/usr/bin/postgres") ->
        "/usr/bin"

      File.regular?("/opt/homebrew/opt/postgresql@17/bin/postgres") ->
        "/opt/homebrew/opt/postgresql@17/bin"

      File.regular?("/opt/homebrew/opt/postgresql@16/bin/postgres") ->
        "/opt/homebrew/opt/postgresql@16/bin"

      File.regular?("/usr/local/bin/postgres") ->
        "/usr/local/bin"

      true ->
        "/usr/bin"
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
      :pg_database,
      :pg_tenant_listen_ip,
      :pg_tenants_file,
      :deploy_secrets_dir
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
