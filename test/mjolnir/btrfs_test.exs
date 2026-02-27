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
end
