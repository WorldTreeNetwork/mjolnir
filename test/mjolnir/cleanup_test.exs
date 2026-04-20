defmodule Mjolnir.CleanupTest do
  @moduledoc """
  Unit tests for the Cleanup module.
  Tests orphan detection logic without requiring root or real hypervisors.
  """
  use ExUnit.Case, async: false

  alias Mjolnir.Cleanup
  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  describe "sweep/0" do
    test "returns :ok even when nothing to clean" do
      # sweep should never crash, even if socket_dir doesn't exist
      assert :ok = Cleanup.sweep()
    end
  end

  describe "process names" do
    test "includes all expected hypervisor process names" do
      names = Cleanup.hypervisor_process_names()
      assert "virtiofsd" in names
      assert "cloud-hypervisor" in names
      assert "firecracker" in names
    end
  end

  describe "stale VM subvolume handling" do
    setup do
      tmp_btrfs =
        Path.join([
          System.tmp_dir!(),
          "mjolnir-cleanup-test",
          "#{System.unique_integer([:positive])}"
        ])

      tmp_state = Path.join(tmp_btrfs, "state")
      File.mkdir_p!(Path.join(tmp_btrfs, "@vms"))
      File.mkdir_p!(tmp_state)
      File.mkdir_p!(Path.join(tmp_state, "quarantine"))

      prev_btrfs = Application.get_env(:mjolnir, :btrfs_root)
      prev_state = Application.get_env(:mjolnir, :state_dir)
      Application.put_env(:mjolnir, :btrfs_root, tmp_btrfs)
      Application.put_env(:mjolnir, :state_dir, tmp_state)
      :ok = StateStore.reload()

      on_exit(fn ->
        File.rm_rf!(tmp_btrfs)
        if prev_btrfs, do: Application.put_env(:mjolnir, :btrfs_root, prev_btrfs)
        if prev_state, do: Application.put_env(:mjolnir, :state_dir, prev_state)
        :ok = StateStore.reload()
      end)

      {:ok, btrfs_root: tmp_btrfs, state_dir: tmp_state}
    end

    test "preserves subvolumes that have a matching state record", ctx do
      uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      path = Path.join([ctx.btrfs_root, "@vms", uuid])
      File.mkdir_p!(path)
      File.write!(Path.join(path, "sentinel"), "keep me")

      :ok = StateStore.put(Record.new(uuid, :running))

      assert :ok = Cleanup.sweep()
      assert File.exists?(path), "Preserved VMs must not be wiped by Cleanup"
      assert File.read!(Path.join(path, "sentinel")) == "keep me"
    end

    test "removes orphan subvolumes without a state record", ctx do
      uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      path = Path.join([ctx.btrfs_root, "@vms", uuid])
      File.mkdir_p!(path)

      assert :ok = Cleanup.sweep()
      refute File.exists?(path), "Orphan (no state record) must be cleaned"
    end

    test "preserves dormant and stopped subvolumes too", ctx do
      dormant_uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      stopped_uuid = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      dormant_path = Path.join([ctx.btrfs_root, "@vms", dormant_uuid])
      stopped_path = Path.join([ctx.btrfs_root, "@vms", stopped_uuid])
      File.mkdir_p!(dormant_path)
      File.mkdir_p!(stopped_path)

      :ok = StateStore.put(Record.new(dormant_uuid, :dormant))
      :ok = StateStore.put(Record.new(stopped_uuid, :stopped))

      assert :ok = Cleanup.sweep()
      assert File.exists?(dormant_path)
      assert File.exists?(stopped_path)
    end

    test "mixed: preserves known, deletes unknown", ctx do
      known = "11111111-1111-1111-1111-111111111111"
      orphan = "22222222-2222-2222-2222-222222222222"
      known_path = Path.join([ctx.btrfs_root, "@vms", known])
      orphan_path = Path.join([ctx.btrfs_root, "@vms", orphan])
      File.mkdir_p!(known_path)
      File.mkdir_p!(orphan_path)

      :ok = StateStore.put(Record.new(known, :running))

      assert :ok = Cleanup.sweep()
      assert File.exists?(known_path)
      refute File.exists?(orphan_path)
    end
  end
end
