defmodule Mjolnir.Postgres.ServerTest do
  @moduledoc """
  Lifecycle tests for `Mjolnir.Postgres.Server`. Tagged `:postgres` — opt in
  with `mix test --include postgres`. Requires `postgres`, `initdb`, and
  `pg_isready` on PATH (or under `pg_bin_dir`).

  Each test gets its own data dir and socket dir under `/tmp` so they can run
  in parallel without colliding on a global instance.
  """

  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Mjolnir.Postgres.{Config, Server}

  setup do
    base = Path.join(System.tmp_dir!(), "mjolnir-pg-test-#{:erlang.unique_integer([:positive])}")
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

    on_exit(fn ->
      restore_env(prev)
      File.rm_rf!(base)
    end)

    {:ok, base: base, data_dir: data_dir, socket_dir: socket_dir}
  end

  test "initdb + start + ready + clean shutdown", ctx do
    refute File.exists?(Path.join(ctx.data_dir, "PG_VERSION"))

    {:ok, pid} = Server.start_link([])

    assert Server.await_ready(15_000) == :ok
    assert File.exists?(Path.join(ctx.data_dir, "PG_VERSION"))
    assert File.exists?(Server.socket_path())
    assert Server.ready?()

    {:os_pid, os_pid} = info_or_nil(pid)
    assert is_integer(os_pid)
    assert pid_alive?(os_pid)

    GenServer.stop(pid, :normal, 15_000)

    refute pid_alive?(os_pid)
  end

  test "writes the expected conf files with ident map", ctx do
    {:ok, pid} = Server.start_link([])
    assert Server.await_ready(15_000) == :ok

    pg_hba = File.read!(Path.join(ctx.data_dir, "pg_hba.conf"))
    pg_ident = File.read!(Path.join(ctx.data_dir, "pg_ident.conf"))
    postgresql = File.read!(Path.join(ctx.data_dir, "postgresql.conf"))

    assert pg_hba =~ "local all all peer map=mjolnir_map"
    assert pg_ident =~ "mjolnir_map"
    assert pg_ident =~ "mjolnir_admin"
    assert pg_ident =~ "mjolnir_sites"
    assert postgresql =~ "listen_addresses = ''"
    refute postgresql =~ "listen_addresses = '*'"
    refute postgresql =~ "0.0.0.0"
    assert postgresql =~ "password_encryption = scram-sha-256"
    assert postgresql =~ "unix_socket_directories = '#{ctx.socket_dir}'"

    GenServer.stop(pid, :normal, 15_000)
  end

  test "second start reuses the existing data dir (no second initdb)", ctx do
    {:ok, pid1} = Server.start_link([])
    assert Server.await_ready(15_000) == :ok
    pg_version = File.read!(Path.join(ctx.data_dir, "PG_VERSION"))
    GenServer.stop(pid1, :normal, 15_000)

    # Touch a marker so we can verify the data dir wasn't wiped.
    marker_path = Path.join(ctx.data_dir, "mjolnir_test_marker")
    File.write!(marker_path, "kept")

    {:ok, pid2} = Server.start_link([])
    assert Server.await_ready(15_000) == :ok
    assert File.read!(marker_path) == "kept"
    assert File.read!(Path.join(ctx.data_dir, "PG_VERSION")) == pg_version

    GenServer.stop(pid2, :normal, 15_000)
  end

  test "missing tenant listen IP fails closed and does not listen on *", ctx do
    Application.put_env(:mjolnir, :pg_tenant_listen_ip, "203.0.113.1")
    refute Mjolnir.Network.ip_assigned?("203.0.113.1")

    assert {:error, {:postgres_start_failed, {:tenant_listen_ip_missing, "203.0.113.1"}}} =
             Server.start_link([])

    conf = Path.join(ctx.data_dir, "postgresql.conf")

    if File.exists?(conf) do
      body = File.read!(conf)
      refute body =~ "listen_addresses = '*'"
      refute body =~ "0.0.0.0"
    end
  end

  test "Config.resolve returns expected paths", ctx do
    cfg = Config.resolve()
    assert cfg.managed == true
    assert cfg.data_dir == ctx.data_dir
    assert cfg.socket_dir == ctx.socket_dir
    assert cfg.bootstrap_role == "mjolnir_admin"
    assert "mjolnir_sites" in cfg.roles
    assert cfg.socket_path == Path.join(ctx.socket_dir, ".s.PGSQL.5432")
  end

  ## Helpers

  defp info_or_nil(pid) do
    case :sys.get_state(pid, 5_000) do
      %{port: port} when not is_nil(port) -> Port.info(port, :os_pid)
      _ -> nil
    end
  end

  defp pid_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
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
      :pg_tenant_listen_ip
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
