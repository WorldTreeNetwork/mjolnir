defmodule Mjolnir.StorageMemoryTest do
  @moduledoc """
  `GET /api/storage` returns `Mjolnir.Storage.overview/0`. Memory snapshots
  are `@snapshots/<name>.mem` directories. Their count and bytes have to show
  up beside the CoW area totals, including a count of 0 when none exist.
  """
  use ExUnit.Case, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "storage-mem-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "@snapshots"))
    prev = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
    end)

    %{root: tmp}
  end

  test "no memory snapshot reports count 0", %{root: root} do
    File.mkdir_p!(Path.join([root, "@snapshots", "fs-only"]))
    File.write!(Path.join([root, "@snapshots", "fs-only", "keep"]), "filesystem snapshot")

    overview = Mjolnir.Storage.overview()

    assert overview.memory_snapshots.count == 0
    assert overview.memory_snapshots.logical_bytes == 0
    assert overview.memory_snapshots.exclusive_bytes == 0
    assert File.exists?(Path.join([root, "@snapshots", "fs-only", "keep"]))
  end

  test "one memory image is counted apart from the snapshots area", %{root: root} do
    payload = :binary.copy(<<0>>, 4096)
    mem = Path.join([root, "@snapshots", "park.mem"])
    File.mkdir_p!(mem)
    File.write!(Path.join(mem, "memory-ranges"), payload)
    File.mkdir_p!(Path.join([root, "@snapshots", "park"]))
    File.write!(Path.join([root, "@snapshots", "park", "root"]), "cow")

    overview = Mjolnir.Storage.overview()
    snap = Enum.find(overview.areas, &(&1.name == "@snapshots"))

    assert overview.memory_snapshots.count == 1
    assert overview.memory_snapshots.logical_bytes == byte_size(payload)
    assert is_integer(overview.memory_snapshots.exclusive_bytes)
    assert overview.memory_snapshots.logical_bytes != snap.total_bytes
    refute snap.count == 0
    assert File.exists?(Path.join([root, "@snapshots", "park", "root"]))
  end
end
