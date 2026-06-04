defmodule Mjolnir.Forge.DiscoverTest do
  @moduledoc """
  Host-wide unmanaged discovery: `Host.discover/1` and `GET /discover`.

  systemd discovery enumerates the sandbox `units_dir`; apt discovery uses the
  apt sandbox ETS table. Not async — global singletons + sandbox config.
  """

  use ExUnit.Case, async: false
  import Plug.Test

  alias Mjolnir.Forge.{Declarations, Host, Store, Supervisor}
  alias Mjolnir.Forge.Resource.AptPackage

  @opts Mjolnir.Forge.API.init([])
  @host "self"

  setup do
    n = System.unique_integer([:positive])
    units_dir = Path.join(System.tmp_dir!(), "forge-disc-units-#{n}")
    decls_dir = Path.join(System.tmp_dir!(), "forge-disc-decls-#{n}")
    state_dir = Path.join(System.tmp_dir!(), "forge-disc-state-#{n}")
    Enum.each([units_dir, decls_dir, state_dir], &File.mkdir_p!/1)

    prev = {
      Application.get_env(:mjolnir, :forge_systemd_units_dir),
      Application.get_env(:mjolnir, :forge_declarations_path),
      Application.get_env(:mjolnir, :forge_state_dir),
      Application.get_env(:mjolnir, :forge_apt_sandbox)
    }

    Application.put_env(:mjolnir, :forge_systemd_units_dir, units_dir)
    Application.put_env(:mjolnir, :forge_declarations_path, decls_dir)
    Application.put_env(:mjolnir, :forge_state_dir, state_dir)
    Application.put_env(:mjolnir, :forge_apt_sandbox, true)

    # Fresh apt sandbox table per test.
    AptPackage.ensure_sandbox_table()
    :ets.delete_all_objects(:forge_apt_sandbox)

    Store.reload()
    Declarations.reload()
    start_host(@host)

    on_exit(fn ->
      {pu, pd, ps, pa} = prev
      Application.put_env(:mjolnir, :forge_systemd_units_dir, pu)
      Application.put_env(:mjolnir, :forge_declarations_path, pd)
      Application.put_env(:mjolnir, :forge_state_dir, ps)
      Application.put_env(:mjolnir, :forge_apt_sandbox, pa)

      if :ets.whereis(:forge_apt_sandbox) != :undefined,
        do: :ets.delete_all_objects(:forge_apt_sandbox)

      Enum.each([units_dir, decls_dir, state_dir], &File.rm_rf/1)
      Store.reload()
      Declarations.reload()
    end)

    %{units_dir: units_dir, n: n}
  end

  defp start_host(host) do
    case Supervisor.start_host(host: host, transport: :local) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp call(method, path), do: Mjolnir.Forge.API.call(conn(method, path), @opts)
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp discover_ids do
    Host.discover(@host) |> Enum.map(fn e -> {e.kind.kind(), e.id, e.status} end)
  end

  defp state_status(id) do
    records = json_body(call(:get, "/state?host=#{@host}"))["records"]
    rec = Enum.find(records, &(&1["resource_id"] == id))
    rec && rec["status"]
  end

  test "discovers an undeclared systemd unit as :unmanaged and stores it", %{
    units_dir: units_dir,
    n: n
  } do
    id = "stray-#{n}.service"
    File.write!(Path.join(units_dir, id), "[Unit]\nDescription=Stray\n")

    found = discover_ids()
    assert {"systemd_unit", id, :unmanaged} in found

    # Persisted to the store → visible via /state for the TUI's 2s poll.
    assert state_status(id) == "unmanaged"
  end

  test "does not surface a declared unit as unmanaged", %{units_dir: units_dir, n: n} do
    id = "declared-#{n}.service"
    source = "[Unit]\nDescription=Declared\n"
    File.write!(Path.join(units_dir, id), source)

    # Declare it (write a hand declaration + reload).
    decl = """
    defmodule Disc#{n} do
      use Mjolnir.Forge.Declaration, host: "#{@host}"
      systemd_unit "#{id}" do
        source #{inspect(source)}
      end
    end
    """

    File.write!(Path.join(Declarations.path(), "#{@host}.exs"), decl)
    :ok = Declarations.reload()

    refute Enum.any?(discover_ids(), fn {_k, found_id, _s} -> found_id == id end)
  end

  test "discovers a manually-installed package via the apt sandbox" do
    :ets.insert(:forge_apt_sandbox, {"htop", %{state: :installed, version: "3.0.5"}})

    assert {"apt_package", "htop", :unmanaged} in discover_ids()
  end

  test "an ignored resource stays ignored across re-discovery (sticky)", %{
    units_dir: units_dir,
    n: n
  } do
    id = "ign-#{n}.service"
    File.write!(Path.join(units_dir, id), "[Unit]\nDescription=Ign\n")

    # First discovery surfaces it as unmanaged.
    assert {"systemd_unit", id, :unmanaged} in discover_ids()

    # Ignore it, then re-discover: sticky_ignore must keep it :ignored.
    :ok = Host.ignore(@host, {Mjolnir.Forge.Resource.SystemdUnit, id})
    assert state_status(id) == "ignored"

    _ = discover_ids()
    assert state_status(id) == "ignored"
  end

  test "GET /discover returns the discovered entries", %{units_dir: units_dir, n: n} do
    id = "ep-#{n}.service"
    File.write!(Path.join(units_dir, id), "[Unit]\nDescription=Endpoint\n")

    conn = call(:get, "/discover?host=#{@host}")
    assert conn.status == 200
    entries = json_body(conn)["entries"]
    entry = Enum.find(entries, &(&1["id"] == id))
    assert entry["status"] == "unmanaged"
    assert entry["kind"] == "systemd_unit"
  end

  test "GET /discover requires a host param" do
    conn = call(:get, "/discover")
    assert conn.status == 400
  end
end
