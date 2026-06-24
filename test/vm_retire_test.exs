defmodule Mjolnir.VMRetireTest do
  @moduledoc """
  Operator retire/revive of stranded :running and :failed records (mjolnir-5fu).
  Exercises the record-level transitions only — no real VM boot — using the
  supervised StateStore with a per-test state_dir, mirroring StateStoreTest.
  """
  use ExUnit.Case, async: false

  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  setup do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "mjolnir-vm-retire-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(tmp)
    File.mkdir_p!(Path.join(tmp, "quarantine"))

    btrfs = Path.join(tmp, "btrfs")
    File.mkdir_p!(Path.join(btrfs, "@vms"))

    prev = Application.get_env(:mjolnir, :state_dir)
    prev_btrfs = Application.get_env(:mjolnir, :btrfs_root)
    Application.put_env(:mjolnir, :state_dir, tmp)
    Application.put_env(:mjolnir, :btrfs_root, btrfs)
    :ok = StateStore.reload()

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:mjolnir, :state_dir, prev)
      if prev_btrfs, do: Application.put_env(:mjolnir, :btrfs_root, prev_btrfs)
      :ok = StateStore.reload()
    end)

    {:ok, state_dir: tmp, btrfs_root: btrfs}
  end

  test "retire flips a stranded :running record to :failed" do
    uuid = "11111111-0000-0000-0000-000000000001"
    :ok = StateStore.put(Record.new(uuid, :running))

    assert :ok = Mjolnir.VM.retire(uuid)
    assert {:ok, %Record{intent: :failed}} = StateStore.get(uuid)
    assert uuid in Enum.map(Mjolnir.VM.list_failed(), & &1.uuid)
  end

  test "retire refuses an unknown record" do
    assert {:error, :not_found} = Mjolnir.VM.retire("does-not-exist")
  end

  test "revive flips :failed back to :running and clears the failure counter" do
    uuid = "11111111-0000-0000-0000-000000000002"

    :ok =
      StateStore.put(
        Record.new(uuid, :failed,
          runtime: %{
            "resume_failures" => 12,
            "first_failure_at" => "2026-06-08T10:00:00Z",
            "last_failure_at" => "2026-06-24T10:00:00Z"
          }
        )
      )

    assert :ok = Mjolnir.VM.revive(uuid)
    assert {:ok, %Record{intent: :running} = back} = StateStore.get(uuid)
    refute Map.has_key?(back.runtime, "resume_failures")
    refute Map.has_key?(back.runtime, "first_failure_at")
    assert Mjolnir.VM.list_failed() == []
  end

  test "revive of an unknown record is a not_found error" do
    assert {:error, :not_found} = Mjolnir.VM.revive("ghost")
  end

  test "forget soft-deletes the rootfs to @trash and removes the record", ctx do
    uuid = "11111111-0000-0000-0000-000000000003"
    rootfs = Path.join([ctx.btrfs_root, "@vms", uuid])
    File.mkdir_p!(rootfs)
    File.write!(Path.join(rootfs, "marker"), "data")

    :ok = StateStore.put(Record.new(uuid, :failed))

    assert :ok = Mjolnir.VM.forget(uuid)
    assert StateStore.get(uuid) == :not_found
    refute File.exists?(rootfs), "original subvolume should be moved out"

    # The data should survive in @trash (durability invariant: never hard-deleted).
    trash = Path.join(ctx.btrfs_root, "@trash")
    trashed = File.ls!(trash)
    assert Enum.any?(trashed, &String.starts_with?(&1, uuid)), "expected a trashed copy"
  end

  test "forget of an unknown record is a not_found error" do
    assert {:error, :not_found} = Mjolnir.VM.forget("ghost")
  end
end
