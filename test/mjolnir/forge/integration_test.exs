defmodule Mjolnir.Forge.IntegrationTest do
  @moduledoc """
  End-to-end exercise of the v0 reconcile loop: write a declaration on disk,
  reload, plan, apply, and verify the file landed + the Store row is
  `:converged`. Uses a tmp directory so no real systemd units are touched.

  Not async — the Forge subsystem is singleton (Store, Declarations,
  HostSupervisor) and these tests mutate shared state.
  """

  use ExUnit.Case, async: false

  alias Mjolnir.Forge.{Declarations, Host, Store, Supervisor}
  alias Mjolnir.Forge.Resource.SystemdUnit

  @host_id "tmp-host-#{System.unique_integer([:positive])}"

  setup do
    # Per-test tmp roots so different runs don't collide.
    n = System.unique_integer([:positive])
    units_dir = Path.join(System.tmp_dir!(), "forge-units-#{n}")
    decls_dir = Path.join(System.tmp_dir!(), "forge-decls-#{n}")
    state_dir = Path.join(System.tmp_dir!(), "forge-state-#{n}")
    File.mkdir_p!(units_dir)
    File.mkdir_p!(decls_dir)
    File.mkdir_p!(state_dir)

    prev_units = Application.get_env(:mjolnir, :forge_systemd_units_dir)
    prev_decls = Application.get_env(:mjolnir, :forge_declarations_path)
    prev_state = Application.get_env(:mjolnir, :forge_state_dir)

    Application.put_env(:mjolnir, :forge_systemd_units_dir, units_dir)
    Application.put_env(:mjolnir, :forge_declarations_path, decls_dir)
    Application.put_env(:mjolnir, :forge_state_dir, state_dir)

    # Reload Store so it picks up the new state_dir.
    Store.reload()
    Declarations.reload()

    on_exit(fn ->
      Application.put_env(:mjolnir, :forge_systemd_units_dir, prev_units)
      Application.put_env(:mjolnir, :forge_declarations_path, prev_decls)
      Application.put_env(:mjolnir, :forge_state_dir, prev_state)
      _ = File.rm_rf(units_dir)
      _ = File.rm_rf(decls_dir)
      _ = File.rm_rf(state_dir)
    end)

    %{units_dir: units_dir, decls_dir: decls_dir, state_dir: state_dir}
  end

  test "declared but absent → plan returns :new; apply writes file; replan returns :converged",
       %{units_dir: units_dir, decls_dir: decls_dir} do
    host = @host_id
    unique = System.unique_integer([:positive])
    mod_name = "ForgeIntegrationDecl#{unique}"

    decl = """
    defmodule #{mod_name} do
      use Mjolnir.Forge.Declaration, host: "#{host}"
      systemd_unit "mjolnir-test.service" do
        source "[Unit]\\nDescription=Test Unit\\n"
      end
    end
    """

    File.write!(Path.join(decls_dir, "#{host}.exs"), decl)
    :ok = Declarations.reload()

    # Worker setup: register the host. start_host is idempotent across runs;
    # this is the first time we see this @host_id so it should be :ok.
    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # PLAN — :new, file does not exist yet
    [entry] = Host.plan(host)
    assert entry.kind == SystemdUnit
    assert entry.id == "mjolnir-test.service"
    assert entry.status == :new
    refute File.exists?(Path.join(units_dir, "mjolnir-test.service"))

    # APPLY — writes the file, no systemctl shell-outs (sandbox mode)
    [{{SystemdUnit, "mjolnir-test.service"}, :ok}] = Host.apply(host, :all_safe)
    assert File.read!(Path.join(units_dir, "mjolnir-test.service")) =~ "Description=Test Unit"

    # REPLAN — :converged, Store row updated with owned_hash + applied_at
    [after_entry] = Host.plan(host)
    assert after_entry.status == :converged
    {:ok, record} = Store.get(host, "systemd_unit", "mjolnir-test.service")
    assert record.status == :converged
    assert record.owned_hash != nil
    assert record.applied_at != nil
  end

  test "declared content drifted on disk → :drifted; re-apply restores",
       %{units_dir: units_dir, decls_dir: decls_dir} do
    host = @host_id <> "-drift"
    unique = System.unique_integer([:positive])
    mod_name = "ForgeDriftDecl#{unique}"

    decl = """
    defmodule #{mod_name} do
      use Mjolnir.Forge.Declaration, host: "#{host}"
      systemd_unit "drifted.service" do
        source "DECLARED"
      end
    end
    """

    File.write!(Path.join(decls_dir, "#{host}.exs"), decl)
    :ok = Declarations.reload()

    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # First apply: file now matches declaration.
    [_] = Host.plan(host)
    [{_, :ok}] = Host.apply(host, :all_safe)
    assert File.read!(Path.join(units_dir, "drifted.service")) == "DECLARED"

    # Simulate hand-edit on the host.
    File.write!(Path.join(units_dir, "drifted.service"), "HAND_EDIT")

    [entry] = Host.plan(host)
    assert entry.status == :drifted

    [{_, :ok}] = Host.apply(host, :all_safe)
    assert File.read!(Path.join(units_dir, "drifted.service")) == "DECLARED"

    [final] = Host.plan(host)
    assert final.status == :converged
  end

  test "removed from declarations + still on disk → :prune; apply deletes file",
       %{units_dir: units_dir, decls_dir: decls_dir} do
    host = @host_id <> "-prune"
    unique = System.unique_integer([:positive])
    mod_name = "ForgePruneDecl#{unique}"

    decl_with = """
    defmodule #{mod_name} do
      use Mjolnir.Forge.Declaration, host: "#{host}"
      systemd_unit "going-away.service" do
        source "TEMP"
      end
    end
    """

    decl_path = Path.join(decls_dir, "#{host}.exs")
    File.write!(decl_path, decl_with)
    :ok = Declarations.reload()

    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    [_] = Host.plan(host)
    [{_, :ok}] = Host.apply(host, :all_safe)
    assert File.exists?(Path.join(units_dir, "going-away.service"))

    # Remove from declarations (write an empty module under a fresh name to
    # avoid redefining `mod_name`, which logs a warning).
    decl_without = """
    defmodule ForgePruneDeclEmpty#{unique} do
      use Mjolnir.Forge.Declaration, host: "#{host}"
    end
    """

    File.write!(decl_path, decl_without)
    :ok = Declarations.reload()

    [entry] = Host.plan(host)
    assert entry.status == :prune

    [{_, :ok}] = Host.apply(host, :all_safe)
    refute File.exists?(Path.join(units_dir, "going-away.service"))
  end
end
