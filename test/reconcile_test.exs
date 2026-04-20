defmodule Mjolnir.ReconcileTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Reconcile
  alias Mjolnir.StateStore.Record

  setup do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-reconcile-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(Path.join(tmp, "@vms"))

    prev = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :btrfs_root, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
    end)

    {:ok, btrfs_root: tmp}
  end

  describe "build_plan/1" do
    test "empty records returns empty plan" do
      assert Reconcile.build_plan([]) == []
    end

    test "record with existing rootfs yields :resume", ctx do
      uuid = "11111111-1111-1111-1111-111111111111"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      record = Record.new(uuid, :running)
      [entry] = Reconcile.build_plan([record])

      assert match?({:resume, ^record, _path}, entry)
      {:resume, _, path} = entry
      assert String.ends_with?(path, uuid)
    end

    test "record with missing rootfs yields :missing_rootfs" do
      uuid = "22222222-2222-2222-2222-222222222222"
      record = Record.new(uuid, :running)
      [entry] = Reconcile.build_plan([record])

      assert match?({:missing_rootfs, ^record, _path}, entry)
    end

    test "mixed records produce appropriate entries", ctx do
      live_uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      gone_uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", live_uuid]))

      plan =
        Reconcile.build_plan([
          Record.new(live_uuid, :running),
          Record.new(gone_uuid, :running)
        ])

      assert Enum.count(plan, fn
               {:resume, _, _} -> true
               _ -> false
             end) == 1

      assert Enum.count(plan, fn
               {:missing_rootfs, _, _} -> true
               _ -> false
             end) == 1
    end
  end

  describe "rootfs_path/1" do
    test "respects configured btrfs_root and subdir", ctx do
      path = Reconcile.rootfs_path("some-uuid")
      assert path == Path.join([ctx.btrfs_root, "@vms", "some-uuid"])
    end
  end
end
