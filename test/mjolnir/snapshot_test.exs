defmodule Mjolnir.SnapshotTest do
  @moduledoc """
  Integration tests for BTRFS snapshot creation and restoration.
  Tests the full snapshot lifecycle: create, list, restore, delete.
  """
  use Mjolnir.VMCase

  @moduletag :integration
  @moduletag :snapshot
  @moduletag timeout: 120_000

  describe "snapshot create" do
    test "creates a named snapshot from a running VM" do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

      # Write a marker file
      {:ok, _} = Mjolnir.VM.exec(vm.id, "echo 'snapshot-test-marker' > /root/marker.txt")

      # Create snapshot
      snapshot_name = "test-snap-#{System.os_time(:second)}"
      assert {:ok, metadata} = Mjolnir.VM.snapshot(vm.id, snapshot_name)
      assert metadata.name == snapshot_name

      on_exit(fn ->
        Mjolnir.BTRFS.delete_snapshot(snapshot_name)
      end)
    end

    test "snapshot name appears in snapshot list" do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

      snapshot_name = "test-list-#{System.os_time(:second)}"
      {:ok, _} = Mjolnir.VM.snapshot(vm.id, snapshot_name)

      on_exit(fn -> Mjolnir.BTRFS.delete_snapshot(snapshot_name) end)

      {:ok, snapshots} = Mjolnir.BTRFS.list_snapshots()
      assert Enum.any?(snapshots, fn s -> s.name == snapshot_name end)
    end
  end

  describe "snapshot restore" do
    test "restores VM with preserved state" do
      # Phase 1: Create VM and write state
      {:ok, vm1} = Mjolnir.VM.spawn()
      {:ok, _} = Mjolnir.VM.exec(vm1.id, "echo 'restore-marker-123' > /root/state.txt")

      snapshot_name = "test-restore-#{System.os_time(:second)}"
      {:ok, _} = Mjolnir.VM.snapshot(vm1.id, snapshot_name)
      :ok = Mjolnir.VM.stop(vm1.id)

      on_exit(fn -> Mjolnir.BTRFS.delete_snapshot(snapshot_name) end)

      # Phase 2: Restore from snapshot
      {:ok, vm2} = Mjolnir.VM.spawn(%{snapshot: snapshot_name})
      on_exit(fn -> Mjolnir.VM.stop(vm2.id) end)

      # Verify state was preserved
      {:ok, output} = Mjolnir.VM.exec(vm2.id, "cat /root/state.txt")
      assert String.trim(output) == "restore-marker-123"
    end

    test "restored VM gets a new unique ID" do
      {:ok, vm1} = Mjolnir.VM.spawn()

      snapshot_name = "test-newid-#{System.os_time(:second)}"
      {:ok, _} = Mjolnir.VM.snapshot(vm1.id, snapshot_name)
      :ok = Mjolnir.VM.stop(vm1.id)

      on_exit(fn -> Mjolnir.BTRFS.delete_snapshot(snapshot_name) end)

      {:ok, vm2} = Mjolnir.VM.spawn(%{snapshot: snapshot_name})
      on_exit(fn -> Mjolnir.VM.stop(vm2.id) end)

      assert vm2.id != vm1.id, "Restored VM should have a new UUID"
      assert vm2.state == :running
    end

    test "restored VM has working networking" do
      {:ok, vm1} = Mjolnir.VM.spawn()

      snapshot_name = "test-net-#{System.os_time(:second)}"
      {:ok, _} = Mjolnir.VM.snapshot(vm1.id, snapshot_name)
      :ok = Mjolnir.VM.stop(vm1.id)

      on_exit(fn -> Mjolnir.BTRFS.delete_snapshot(snapshot_name) end)

      {:ok, vm2} = Mjolnir.VM.spawn(%{snapshot: snapshot_name})
      on_exit(fn -> Mjolnir.VM.stop(vm2.id) end)

      # Verify network is configured
      {:ok, output} = Mjolnir.VM.exec(vm2.id, "ip -4 addr show eth0")
      assert output =~ vm2.net_config.guest_ip
    end
  end

  describe "snapshot delete" do
    test "deleting a snapshot removes it from the list" do
      {:ok, vm} = Mjolnir.VM.spawn()
      on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

      snapshot_name = "test-delete-#{System.os_time(:second)}"
      {:ok, _} = Mjolnir.VM.snapshot(vm.id, snapshot_name)

      # Delete it
      :ok = Mjolnir.BTRFS.delete_snapshot(snapshot_name)

      {:ok, snapshots} = Mjolnir.BTRFS.list_snapshots()
      refute Enum.any?(snapshots, fn s -> s.name == snapshot_name end)
    end
  end
end
