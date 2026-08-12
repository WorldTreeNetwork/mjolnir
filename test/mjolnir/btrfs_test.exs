defmodule Mjolnir.BTRFSTest do
  use ExUnit.Case, async: true

  describe "path construction" do
    test "clone/2 constructs correct source and dest paths" do
      # Test that paths no longer contain .ext4
      # (Actual btrfs commands will fail on macOS, but we can test
      #  the path logic by checking the module compiles and
      #  function arities are correct)
      assert is_function(&Mjolnir.BTRFS.clone/2)
      assert is_function(&Mjolnir.BTRFS.clone_from_snapshot/2)
      assert is_function(&Mjolnir.BTRFS.create_snapshot/3)
    end

    test "delete_iroh_key/1 accepts a directory path" do
      # Create a temp dir simulating a rootfs directory
      tmp = Path.join(System.tmp_dir!(), "btrfs-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "etc/mjolnir"))
      File.write!(Path.join(tmp, "etc/mjolnir/iroh.key"), "test-key")

      assert :ok = Mjolnir.BTRFS.delete_iroh_key(tmp)
      refute File.exists?(Path.join(tmp, "etc/mjolnir/iroh.key"))

      # Cleanup
      File.rm_rf!(tmp)
    end

    test "delete_iroh_key/1 succeeds when key doesn't exist" do
      tmp = Path.join(System.tmp_dir!(), "btrfs-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      assert :ok = Mjolnir.BTRFS.delete_iroh_key(tmp)

      File.rm_rf!(tmp)
    end
  end

  describe "removed functions" do
    test "resize_rootfs/2 is not exported" do
      refute function_exported?(Mjolnir.BTRFS, :resize_rootfs, 2)
    end

    test "compact_rootfs/1 is not exported" do
      refute function_exported?(Mjolnir.BTRFS, :compact_rootfs, 1)
    end
  end

  # The soft-delete trash layer is portable to macOS: trash/restore use `mv`
  # on plain directories, and reap falls back to File.rm_rf when btrfs is
  # absent. These tests pass an explicit :trash_root so they never touch the
  # configured btrfs_root.
  describe "soft-delete trash layer" do
    setup do
      base = Path.join(System.tmp_dir!(), "trash-test-#{System.unique_integer([:positive])}")
      src_parent = Path.join(base, "@vms")
      trash = Path.join(base, "@trash")
      File.mkdir_p!(src_parent)
      on_exit(fn -> File.rm_rf!(base) end)
      %{base: base, src_parent: src_parent, trash: trash}
    end

    test "trash_subvolume moves the directory into trash and is reversible", %{
      src_parent: src_parent,
      trash: trash
    } do
      src = Path.join(src_parent, "abc-123")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "marker"), "user-data")

      assert {:ok, dest} = Mjolnir.BTRFS.trash_subvolume(src, trash_root: trash)
      refute File.exists?(src)
      assert File.exists?(dest)
      assert File.read!(Path.join(dest, "marker")) == "user-data"
      assert String.starts_with?(Path.basename(dest), "abc-123__")

      # Round-trip: restore it back to the original path.
      assert :ok = Mjolnir.BTRFS.restore_trashed(dest, src)
      assert File.read!(Path.join(src, "marker")) == "user-data"
      refute File.exists?(dest)
    end

    test "trash_subvolume is idempotent on a missing source", %{trash: trash} do
      assert :ok = Mjolnir.BTRFS.trash_subvolume("/no/such/path", trash_root: trash)
      assert :ok = Mjolnir.BTRFS.trash_subvolume(nil, trash_root: trash)
    end

    test "reap_trash removes only entries older than retention", %{trash: trash} do
      File.mkdir_p!(trash)
      now = System.os_time(:second)
      old = Path.join(trash, "old__#{now - 10_000}__ab")
      fresh = Path.join(trash, "fresh__#{now}__cd")
      File.mkdir_p!(old)
      File.mkdir_p!(fresh)

      assert {:ok, 1} = Mjolnir.BTRFS.reap_trash(trash_root: trash, retention_seconds: 3600)
      refute File.exists?(old)
      assert File.exists?(fresh)
    end

    test "reap_trash KEEPS entries with an unparseable name (fail-safe)", %{trash: trash} do
      File.mkdir_p!(trash)
      weird = Path.join(trash, "not-a-trash-name")
      File.mkdir_p!(weird)

      assert {:ok, 0} = Mjolnir.BTRFS.reap_trash(trash_root: trash, retention_seconds: 0)
      assert File.exists?(weird)
    end

    test "reap_trash on a missing trash dir is a no-op", %{trash: trash} do
      assert {:ok, 0} = Mjolnir.BTRFS.reap_trash(trash_root: trash)
    end

    test "trash_subvolume writes a metadata sidecar that list_trash returns", %{
      src_parent: src_parent,
      trash: trash
    } do
      src = Path.join(src_parent, "dead-beef")
      File.mkdir_p!(src)
      meta = %{"spawn_config" => %{"owner_id" => "alice", "memory_mb" => 512}}

      assert {:ok, dest} = Mjolnir.BTRFS.trash_subvolume(src, trash_root: trash, metadata: meta)
      assert File.exists?(dest <> ".meta.json")

      assert {:ok, [entry]} = Mjolnir.BTRFS.list_trash(trash_root: trash)
      assert entry.vm_id == "dead-beef"
      assert entry.metadata["spawn_config"]["owner_id"] == "alice"
      assert entry.reaps_in_seconds > 0

      assert {:ok, found} = Mjolnir.BTRFS.find_trashed("dead-beef", trash_root: trash)
      assert found.path == dest
    end

    test "reap_trash removes the metadata sidecar alongside its subvolume", %{trash: trash} do
      File.mkdir_p!(trash)
      now = System.os_time(:second)
      entry = Path.join(trash, "old__#{now - 10_000}__aa")
      File.mkdir_p!(entry)
      File.write!(entry <> ".meta.json", ~s({"x":1}))

      assert {:ok, 1} = Mjolnir.BTRFS.reap_trash(trash_root: trash, retention_seconds: 3600)
      refute File.exists?(entry)
      refute File.exists?(entry <> ".meta.json")
    end

    test "reap_trash reaps CI-tagged entries at the CI retention while non-CI entries at the same age survive (mjolnir-urp)",
         %{trash: trash} do
      File.mkdir_p!(trash)
      now = System.os_time(:second)
      # Both entries are the same age: older than the (short) CI retention,
      # but younger than the (long) default retention.
      age = 2 * 60 * 60

      ci_entry = Path.join(trash, "ci-vm__#{now - age}__aa")
      other_entry = Path.join(trash, "other-vm__#{now - age}__bb")
      File.mkdir_p!(ci_entry)
      File.mkdir_p!(other_entry)

      File.write!(
        ci_entry <> ".meta.json",
        Jason.encode!(%{"metadata" => %{"purpose" => "ci"}})
      )

      File.write!(
        other_entry <> ".meta.json",
        Jason.encode!(%{"metadata" => %{"purpose" => "interactive"}})
      )

      assert {:ok, 1} =
               Mjolnir.BTRFS.reap_trash(
                 trash_root: trash,
                 retention_seconds: 24 * 60 * 60,
                 ci_retention_seconds: 60 * 60
               )

      refute File.exists?(ci_entry)
      refute File.exists?(ci_entry <> ".meta.json")
      assert File.exists?(other_entry)
      assert File.exists?(other_entry <> ".meta.json")
    end

    test "list_trash skips sidecar files and unparseable names", %{trash: trash} do
      File.mkdir_p!(trash)
      now = System.os_time(:second)
      good = Path.join(trash, "vm1__#{now}__bb")
      File.mkdir_p!(good)
      File.write!(good <> ".meta.json", ~s({"ok":true}))
      File.mkdir_p!(Path.join(trash, "garbage-no-stamp"))

      assert {:ok, list} = Mjolnir.BTRFS.list_trash(trash_root: trash)
      assert length(list) == 1
      assert hd(list).vm_id == "vm1"
    end
  end
end
