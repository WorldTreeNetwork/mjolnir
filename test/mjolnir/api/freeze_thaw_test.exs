defmodule Mjolnir.API.FreezeThawTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mjolnir.API.Router

  @opts Router.init([])

  setup do
    original_auth = Application.get_env(:mjolnir, :auth, [])
    Application.put_env(:mjolnir, :auth, bypass_localhost: true)

    tmp = Path.join(System.tmp_dir!(), "freeze-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "@snapshots"))
    prev_root = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, tmp)

    on_exit(fn ->
      Application.put_env(:mjolnir, :auth, original_auth)
      if prev_root, do: Application.put_env(:mjolnir, :btrfs_root, prev_root)
      File.rm_rf(tmp)
    end)

    {:ok, root: tmp}
  end

  defp request(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp write_snapshot(root, name, attrs) do
    meta =
      Map.merge(
        %{
          "name" => name,
          "source_vm_id" => "vm-1",
          "owner_id" => "localhost",
          "created_at" => "2026-09-03T00:00:00Z",
          "size_bytes" => 1
        },
        attrs
      )

    File.write!(
      Path.join([root, "@snapshots", "#{name}.json"]),
      Jason.encode!(meta)
    )

    File.mkdir_p!(Path.join([root, "@snapshots", name]))
  end

  describe "GET /api/snapshots kind" do
    test "filesystem vs memory", %{root: root} do
      write_snapshot(root, "fs-only", %{})
      write_snapshot(root, "frozen", %{})
      mem = Path.join([root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")

      conn = request(:get, "/api/snapshots")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      by_name = Map.new(body["snapshots"], &{&1["name"], &1["kind"]})
      assert by_name["fs-only"] == "filesystem"
      assert by_name["frozen"] == "memory"

      show = request(:get, "/api/snapshots/frozen")
      assert show.status == 200
      assert Jason.decode!(show.resp_body)["kind"] == "memory"
    end
  end

  describe "POST /api/vms/:id/freeze" do
    test "404 when the VM does not exist" do
      conn = request(:post, "/api/vms/no-such-vm/freeze", %{name: "parked"})
      assert conn.status == 404
    end

    test "400 when name is missing" do
      conn = request(:post, "/api/vms/no-such-vm/freeze", %{})
      assert conn.status == 400
    end
  end

  describe "POST /api/snapshots/:name/thaw" do
    test "404 when the snapshot does not exist" do
      conn = request(:post, "/api/snapshots/nope/thaw")
      assert conn.status == 404
    end

    test "400 for a filesystem-only snapshot", %{root: root} do
      write_snapshot(root, "fs-only", %{})
      conn = request(:post, "/api/snapshots/fs-only/thaw")
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_a_memory_snapshot"
    end
  end

  describe "POST /api/vms spawn from memory snapshot" do
    test "refuses rather than cold-booting", %{root: root} do
      write_snapshot(root, "frozen", %{})
      mem = Path.join([root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")

      conn = request(:post, "/api/vms", %{snapshot: "frozen"})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "memory_snapshot_requires_thaw"
      assert body["snapshot"] == "frozen"
    end
  end
end
