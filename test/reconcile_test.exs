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

  describe "note_failure/2 (retirement policy)" do
    setup do
      prev_max = Application.get_env(:mjolnir, :reconcile_max_failures)
      prev_ttl = Application.get_env(:mjolnir, :reconcile_failure_ttl_seconds)
      Application.put_env(:mjolnir, :reconcile_max_failures, 3)
      Application.put_env(:mjolnir, :reconcile_failure_ttl_seconds, 3600)

      on_exit(fn ->
        restore(:reconcile_max_failures, prev_max)
        restore(:reconcile_failure_ttl_seconds, prev_ttl)
      end)

      :ok
    end

    test "first failure increments counter and stamps timestamps, stays :running" do
      now = ~U[2026-06-24 12:00:00Z]
      record = Record.new("u1", :running)

      assert {:retry, updated} = Reconcile.note_failure(record, now)
      assert updated.intent == :running
      assert updated.runtime["resume_failures"] == 1
      assert updated.runtime["first_failure_at"] == DateTime.to_iso8601(now)
      assert updated.runtime["last_failure_at"] == DateTime.to_iso8601(now)
    end

    test "subsequent failures keep the original first_failure_at and bump count" do
      now1 = ~U[2026-06-24 12:00:00Z]
      now2 = ~U[2026-06-24 12:00:30Z]

      {:retry, r1} = Reconcile.note_failure(Record.new("u2", :running), now1)
      {:retry, r2} = Reconcile.note_failure(r1, now2)

      assert r2.runtime["resume_failures"] == 2
      assert r2.runtime["first_failure_at"] == DateTime.to_iso8601(now1)
      assert r2.runtime["last_failure_at"] == DateTime.to_iso8601(now2)
    end

    test "retires to :failed once the count threshold is reached" do
      now = ~U[2026-06-24 12:00:00Z]

      {:retry, r1} = Reconcile.note_failure(Record.new("u3", :running), now)
      {:retry, r2} = Reconcile.note_failure(r1, now)
      # 3rd consecutive failure == reconcile_max_failures (3)
      assert {:retire, r3} = Reconcile.note_failure(r2, now)
      assert r3.intent == :failed
      assert r3.runtime["resume_failures"] == 3
    end

    test "retires on TTL even when the count is below threshold" do
      first = ~U[2026-06-24 12:00:00Z]
      # one hour and one second later — exceeds the 3600s TTL on the 2nd failure
      later = ~U[2026-06-24 13:00:01Z]

      {:retry, r1} = Reconcile.note_failure(Record.new("u4", :running), first)
      assert {:retire, r2} = Reconcile.note_failure(r1, later)
      assert r2.intent == :failed
      assert r2.runtime["resume_failures"] == 2
    end
  end

  defp restore(key, nil), do: Application.delete_env(:mjolnir, key)
  defp restore(key, val), do: Application.put_env(:mjolnir, key, val)
end
