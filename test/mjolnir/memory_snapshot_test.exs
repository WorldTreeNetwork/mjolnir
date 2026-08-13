defmodule Mjolnir.MemorySnapshotTest do
  @moduledoc """
  mjolnir-3y6.3 — the correctness keystone.

  A restored guest's RAM holds a page cache that describes a specific on-disk
  state. Hand it a filesystem that has moved and you get silent corruption, not
  a crash. These tests pin the parts of that guarantee that are decidable
  without a BTRFS host: generation parsing, the drift refusal, and the layout
  rule that keeps CH's writable artifacts out of a read-only subvolume.

  The rule that restore never mounts the live `@vms/<id>` subvolume is
  structural — `prepare_thaw/2` returns a clone path under a *new* vm id — and
  the end-to-end proof (freeze, thaw, marker process still at the same PID)
  needs KVM and lives in the integration suite.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.BTRFS
  alias Mjolnir.MemorySnapshot

  describe "parse_generation/1" do
    @show_output """
    @snapshots/frozen-1
    \tName: \t\t\tfrozen-1
    \tUUID: \t\t\t7bb1f0a2-1c0e-2f4e-9ab1-2f1e5c8d9a01
    \tParent UUID: \t\t3a0c11de-4d5f-6071-8293-a4b5c6d7e8f9
    \tCreation time: \t\t2026-08-13 09:00:00 +0000
    \tSubvolume ID: \t\t312
    \tGeneration: \t\t4471
    \tGen at creation: \t4471
    \tParent ID: \t\t5
    \tFlags: \t\t\treadonly
    """

    test "reads the Generation field" do
      assert {:ok, 4471} = BTRFS.parse_generation(@show_output)
    end

    test "does not match 'Gen at creation'" do
      # The two fields differ precisely when a read-only snapshot has been
      # flipped writable and modified — the case this whole mechanism exists to
      # catch. Matching the wrong line would make drift undetectable.
      drifted = String.replace(@show_output, "Generation: \t\t4471", "Generation: \t\t4600")
      assert {:ok, 4600} = BTRFS.parse_generation(drifted)
    end

    test "reports a missing field rather than guessing" do
      assert {:error, :generation_not_found} = BTRFS.parse_generation("Name:\tfoo\n")
      assert {:error, :generation_not_found} = BTRFS.parse_generation("")
    end

    test "tolerates leading whitespace variation" do
      assert {:ok, 12} = BTRFS.parse_generation("   Generation:   12   \n")
    end
  end

  describe "memory_dir/1" do
    setup do
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, "/mnt/btrfs")
      on_exit(fn -> if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev) end)
      :ok
    end

    test "sits beside the snapshot subvolume, not inside it" do
      # The subvolume is created read-only so it cannot drift; CH must still be
      # able to write config.json/state.json/memory-ranges. Nesting them would
      # force the subvolume to be writable and undo the pin.
      assert MemorySnapshot.memory_dir("frozen-1") == "/mnt/btrfs/@snapshots/frozen-1.mem"
    end
  end

  describe "memory_snapshot?/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "memsnap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots"))
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      {:ok, root: tmp}
    end

    test "false when only a filesystem snapshot exists", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "fs-only"]))
      refute MemorySnapshot.memory_snapshot?("fs-only")
    end

    test "true once CH has written state.json", ctx do
      mem = Path.join([ctx.root, "@snapshots", "frozen.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")
      assert MemorySnapshot.memory_snapshot?("frozen")
    end

    test "false for a memory dir that exists but is empty", ctx do
      # A freeze that failed partway leaves a directory behind. Treating its
      # existence as proof would send a caller down the thaw path with no RAM
      # image to restore.
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "half-written.mem"]))
      refute MemorySnapshot.memory_snapshot?("half-written")
    end
  end

  describe "prepare_thaw/2 refusals" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "memsnap-thaw-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots"))
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      {:ok, root: tmp}
    end

    test "refuses when there is no memory image", ctx do
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "fs-only"]))

      assert {:error, {:memory_snapshot_not_found, "fs-only"}} =
               MemorySnapshot.prepare_thaw("fs-only", "new-vm-id")
    end

    test "refuses a snapshot whose sidecar records no generation", ctx do
      # Pre-pinning snapshots cannot prove their filesystem is unchanged. For a
      # cold boot that is merely stale; for a memory restore it is potential
      # silent corruption, so an unprovable pin is treated as a failed pin.
      mem = Path.join([ctx.root, "@snapshots", "legacy.mem"])
      File.mkdir_p!(mem)
      File.write!(Path.join(mem, "state.json"), "{}")
      File.mkdir_p!(Path.join([ctx.root, "@snapshots", "legacy"]))

      File.write!(
        Path.join([ctx.root, "@snapshots", "legacy.json"]),
        Jason.encode!(%{name: "legacy", created_at: "2026-01-01T00:00:00Z"})
      )

      assert {:error, {:snapshot_generation_unknown, "legacy"}} =
               MemorySnapshot.prepare_thaw("legacy", "new-vm-id")
    end
  end
end
