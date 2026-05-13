defmodule Mjolnir.Postgres.SupervisorTest do
  @moduledoc """
  End-to-end test for the full Postgres supervision tree: Server → Bootstrap
  → Migrator → Repo. Verifies that on cold start the data dir is initialized,
  roles + database + schema are bootstrapped, migrations are applied, and the
  app Repo can read/write the sites tables.
  """

  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Postgres.{Config, Migrator, Server}
  alias Mjolnir.Repo

  setup do
    base =
      Path.join(System.tmp_dir!(), "mjolnir-pg-sup-#{:erlang.unique_integer([:positive])}")

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

    on_exit(fn ->
      restore_env(prev)
      File.rm_rf!(base)
    end)

    {:ok, base: base, socket_dir: socket_dir}
  end

  test "full supervision tree comes up cold, applies migrations, repo is queryable", ctx do
    {:ok, sup} = start_supervised(Mjolnir.Postgres.Supervisor)
    assert is_pid(sup)
    assert Server.ready?()

    # Both sites tables should exist after migrations
    {:ok, conn} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: "mjolnir",
        backoff_type: :stop
      )

    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'sites' ORDER BY table_name
        """,
        []
      )

    table_names = Enum.map(rows, &hd/1)
    assert "head_index" in table_names
    assert "manifest_index" in table_names

    GenServer.stop(conn, :normal, 5_000)

    # Mjolnir.Repo (mjolnir_sites role) can write and read its tables
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        "head_index",
        [
          %{
            identikey_fp: "fp-test",
            site_name: "blog",
            snapshot_hash: "hash-1",
            sequence: 1,
            updated_at: now
          }
        ],
        prefix: "sites"
      )

    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM sites.head_index WHERE identikey_fp = $1", ["fp-test"])

    assert count == 1
  end

  test "Migrator.migrate is idempotent — running it again is a no-op", ctx do
    {:ok, _sup} = start_supervised(Mjolnir.Postgres.Supervisor)
    assert Server.ready?()

    # First run already happened in init. Run again explicitly.
    assert :ok = Migrator.migrate()
    assert :ok = Migrator.migrate()

    cfg = Config.resolve()
    assert cfg.db_name == "mjolnir"

    {:ok, conn} =
      Postgrex.start_link(
        socket_dir: ctx.socket_dir,
        username: "mjolnir_admin",
        database: cfg.db_name,
        backoff_type: :stop
      )

    %{rows: [[migration_count]]} =
      Postgrex.query!(conn, "SELECT count(*) FROM public.schema_migrations", [])

    assert migration_count == 2

    GenServer.stop(conn, :normal, 5_000)
  end

  ## Helpers

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
