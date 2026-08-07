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

  describe "restart_policy — build_plan/1 (mjolnir-yhr)" do
    test "restart_policy=never yields :finalize, never :resume", ctx do
      uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      record = Record.new(uuid, :running, spawn_config: %{"restart_policy" => "never"})

      assert [{:finalize, ^record, path}] = Reconcile.build_plan([record])
      assert String.ends_with?(path, uuid)
    end

    test "the policy holds even when the rootfs is gone" do
      # A :never record whose data has vanished must still not be treated as a
      # resume candidate — the policy is about restarting, not about recovery.
      uuid = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      record = Record.new(uuid, :running, spawn_config: %{"restart_policy" => "never"})

      assert [{:finalize, ^record, _}] = Reconcile.build_plan([record])
    end

    test "restart_policy=always resumes, as before", ctx do
      uuid = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      record = Record.new(uuid, :running, spawn_config: %{"restart_policy" => "always"})
      assert [{:resume, ^record, _}] = Reconcile.build_plan([record])
    end

    test "a record with no policy at all resumes — the default is unchanged", ctx do
      uuid = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      assert [{:resume, _, _}] = Reconcile.build_plan([Record.new(uuid, :running)])
    end
  end

  describe "restart_policy/1" do
    test "only the exact string \"never\" means never" do
      assert Reconcile.restart_policy(rec_with(%{"restart_policy" => "never"})) == :never
    end

    test "fails open to :always on anything unrecognised" do
      # Deliberate: a typo'd or half-migrated policy must not silently become
      # "never restart this VM" — that strands a fleet, and only shows up during
      # the recovery you were relying on.
      for value <- ["Never", "NEVER", "nope", "", nil, 1, %{}] do
        assert Reconcile.restart_policy(rec_with(%{"restart_policy" => value})) == :always,
               "expected #{inspect(value)} to read as :always"
      end

      assert Reconcile.restart_policy(rec_with(%{})) == :always
    end

    defp rec_with(spawn_config) do
      Record.new("policy-test", :running, spawn_config: spawn_config)
    end
  end

  describe "read_harness_exit/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "harness-exit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "var/lib/buzz"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, rootfs: dir}
    end

    test "parses the three known keys", ctx do
      write_exit(ctx.rootfs, "exit_reason=exited\nexit_status=0\nservice_result=success\n")

      assert Reconcile.read_harness_exit(ctx.rootfs) == %{
               "harness_exit_reason" => "exited",
               "harness_exit_status" => "0",
               "harness_service_result" => "success"
             }
    end

    test "ignores unknown keys and junk lines", ctx do
      write_exit(ctx.rootfs, "exit_reason=killed\ngarbage\nBUZZ_PRIVATE_KEY=nsec1leak\n")

      evidence = Reconcile.read_harness_exit(ctx.rootfs)

      assert evidence == %{"harness_exit_reason" => "killed"}
      # The marker is guest-controlled. Only the three known keys are kept, so a
      # guest cannot smuggle arbitrary content onto the host's durable record.
      refute Enum.any?(evidence, fn {_k, v} -> String.contains?(v, "nsec1") end)
    end

    test "returns empty when there is no marker — the common case", ctx do
      assert Reconcile.read_harness_exit(ctx.rootfs) == %{}
    end

    test "refuses an oversized marker rather than reading it into the record", ctx do
      write_exit(ctx.rootfs, "exit_reason=exited\n" <> String.duplicate("x", 8_192))
      assert Reconcile.read_harness_exit(ctx.rootfs) == %{}
    end

    defp write_exit(rootfs, contents) do
      File.write!(Path.join(rootfs, "var/lib/buzz/harness-exit"), contents)
    end
  end

  describe "rootfs_path/1" do
    test "respects configured btrfs_root and subdir", ctx do
      path = Reconcile.rootfs_path("some-uuid")
      assert path == Path.join([ctx.btrfs_root, "@vms", "some-uuid"])
    end
  end

  describe "run/0 with restart_policy=never (mjolnir-yhr)" do
    setup ctx do
      # Reuse the supervised StateStore with a per-test state_dir, the same way
      # state_store_test.exs does — stopping it ourselves would race the
      # supervisor.
      state_dir = Path.join(ctx.btrfs_root, "state")
      File.mkdir_p!(Path.join(state_dir, "quarantine"))

      prev = Application.get_env(:mjolnir, :state_dir)
      Application.put_env(:mjolnir, :state_dir, state_dir)
      :ok = Mjolnir.StateStore.reload()

      on_exit(fn ->
        if prev, do: Application.put_env(:mjolnir, :state_dir, prev)
        :ok = Mjolnir.StateStore.reload()
      end)

      :ok
    end

    test "finalizes to :stopped instead of resuming, and preserves the rootfs", ctx do
      uuid = "11112222-3333-4444-5555-666677778888"
      rootfs = Path.join([ctx.btrfs_root, "@vms", uuid])
      File.mkdir_p!(Path.join(rootfs, "var/lib/buzz"))

      File.write!(
        Path.join(rootfs, "var/lib/buzz/harness-exit"),
        "exit_reason=exited\nexit_status=0\nservice_result=success\n"
      )

      :ok =
        Mjolnir.StateStore.put(
          Record.new(uuid, :running, spawn_config: %{"restart_policy" => "never"})
        )

      # No VM is booted: a :never record must never reach Mjolnir.VM.resume/1,
      # which would try to start a hypervisor and fail loudly in a unit test.
      assert :ok = Reconcile.run()

      assert {:ok, record} = Mjolnir.StateStore.get(uuid)
      assert record.intent == :stopped
      assert record.runtime["finalized_reason"] == "restart_policy=never"
      assert record.runtime["finalized_at"]

      # Exit evidence is recorded for the operator — it decided nothing.
      assert record.runtime["harness_exit_reason"] == "exited"
      assert record.runtime["harness_exit_status"] == "0"

      # The desk survives: snapshot-resume on the next owner-initiated start
      # clones from this subvolume.
      assert File.exists?(rootfs)
    end

    test "is idempotent — a finalized record is no longer in the stranded set", ctx do
      uuid = "99998888-7777-6666-5555-444433332222"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      :ok =
        Mjolnir.StateStore.put(
          Record.new(uuid, :running, spawn_config: %{"restart_policy" => "never"})
        )

      assert :ok = Reconcile.run()
      {:ok, first} = Mjolnir.StateStore.get(uuid)

      # A second pass must not touch it: run/0 only looks at :running records,
      # so a finalized VM stops costing anything on every Health.Monitor tick.
      assert :ok = Reconcile.run()
      {:ok, second} = Mjolnir.StateStore.get(uuid)

      assert second.intent == :stopped
      assert second.generation == first.generation
    end

    test "finalizes even with no harness marker — a wedged body writes nothing", ctx do
      uuid = "abababab-cdcd-efef-0101-232323232323"
      File.mkdir_p!(Path.join([ctx.btrfs_root, "@vms", uuid]))

      :ok =
        Mjolnir.StateStore.put(
          Record.new(uuid, :running, spawn_config: %{"restart_policy" => "never"})
        )

      assert :ok = Reconcile.run()
      assert {:ok, record} = Mjolnir.StateStore.get(uuid)

      assert record.intent == :stopped
      refute Map.has_key?(record.runtime, "harness_exit_reason")
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
