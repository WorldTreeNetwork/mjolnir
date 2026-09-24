defmodule Mjolnir.VmId.MigrateTest do
  use ExUnit.Case, async: true

  alias Mjolnir.VmId.Migrate

  @uuid "01234567-89ab-cdef-0123-456789abcdef"

  test "renames state, rootfs, and escrow, and stamps the old vsock cid" do
    root = briefly()
    state = Path.join(root, "state")
    btrfs = Path.join(root, "btrfs")
    escrow = Path.join(root, "escrow")
    File.mkdir_p!(state)
    File.mkdir_p!(Path.join([btrfs, "@vms", @uuid]))
    File.mkdir_p!(Path.join(btrfs, "@snapshots"))
    File.mkdir_p!(escrow)

    canonical = Mjolnir.VmId.storage_id(@uuid)
    File.write!(Path.join([btrfs, "@vms", @uuid, "keep"]), "root")
    File.write!(Path.join(escrow, @uuid), "pass")

    File.write!(
      Path.join(btrfs, "@snapshots/box.json"),
      Jason.encode!(%{"name" => "box", "source_vm_id" => @uuid})
    )

    record = %{
      "schema_version" => 2,
      "uuid" => @uuid,
      "intent" => "running",
      "spawn_config" => %{"memory_mb" => 2048}
    }

    File.write!(Path.join(state, @uuid <> ".json"), Jason.encode!(record))

    assert :ok = Migrate.run(state_dir: state, btrfs_root: btrfs, escrow_dir: escrow)

    refute File.exists?(Path.join(state, @uuid <> ".json"))
    migrated = Jason.decode!(File.read!(Path.join(state, canonical <> ".json")))
    assert migrated["uuid"] == canonical
    assert migrated["spawn_config"]["vsock_cid"] == Mjolnir.Vsock.cid(@uuid)
    assert File.read!(Path.join([btrfs, "@vms", canonical, "keep"])) == "root"
    assert File.read!(Path.join(escrow, canonical)) == "pass"

    sidecar = Jason.decode!(File.read!(Path.join(btrfs, "@snapshots/box.json")))
    assert sidecar["source_vm_id"] == canonical

    assert :ok = Migrate.run(state_dir: state, btrfs_root: btrfs, escrow_dir: escrow)
    assert migrated == Jason.decode!(File.read!(Path.join(state, canonical <> ".json")))
  end

  defp briefly do
    path =
      Path.join(
        System.tmp_dir!(),
        "vm-id-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
