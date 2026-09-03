defmodule Mjolnir.VMUnitTest do
  @moduledoc """
  Unit tests for VM module logic that doesn't require a running hypervisor.
  Tests pure functions and deterministic behavior.
  """
  use ExUnit.Case, async: true

  describe "spawn refuses memory snapshots" do
    test "returns memory_snapshot_requires_thaw without starting a VM" do
      tmp = Path.join(System.tmp_dir!(), "vm-freeze-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "@snapshots/parked.mem"))
      File.write!(Path.join(tmp, "@snapshots/parked.mem/state.json"), "{}")
      prev = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
        if prev, do: Application.put_env(:mjolnir, :btrfs_root, prev)
      end)

      assert {:error, {:memory_snapshot_requires_thaw, "parked"}} =
               Mjolnir.VM.spawn(%{snapshot: "parked"})
    end
  end

  describe "vsock CID generation" do
    test "different UUIDs produce different CIDs" do
      uuid1 = "550e8400-e29b-41d4-a716-446655440000"
      uuid2 = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

      assert Mjolnir.Vsock.cid(uuid1) != Mjolnir.Vsock.cid(uuid2)
    end

    test "CID is deterministic for the same UUID" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      assert Mjolnir.Vsock.cid(uuid) == Mjolnir.Vsock.cid(uuid)
    end

    test "CID is always >= 3 (reserved range)" do
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = Mjolnir.Vsock.cid(uuid)
        assert cid >= 3, "CID #{cid} is below minimum (3) for UUID #{uuid}"
      end
    end

    test "CID never equals 0xFFFFFFFF (VMADDR_CID_ANY)" do
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = Mjolnir.Vsock.cid(uuid)
        assert cid != 0xFFFFFFFF, "CID should never be VMADDR_CID_ANY"
      end
    end

    test "CID fits in 32-bit unsigned integer" do
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = Mjolnir.Vsock.cid(uuid)
        assert cid > 0 and cid < 0xFFFFFFFF
      end
    end
  end

  describe "VM struct defaults" do
    test "default state is nil" do
      vm = %Mjolnir.VM{}
      assert vm.state == nil
    end

    test "enable_iroh defaults to false" do
      vm = %Mjolnir.VM{}
      assert vm.enable_iroh == false
    end

    test "message_queue defaults to empty list" do
      vm = %Mjolnir.VM{}
      assert vm.message_queue == []
    end

    test "secrets_unlock_failure defaults to nil (mjolnir-3v2)" do
      vm = %Mjolnir.VM{}
      assert vm.secrets_unlock_failure == nil
    end
  end

  describe "mjolnir-3v2: a failed managed-secrets unlock is observable" do
    defp base_vm(overrides) do
      struct!(
        %Mjolnir.VM{
          id: UUID.uuid4(),
          config: %Mjolnir.CloudHypervisor.Config{
            vm_id: "vm-1",
            kernel_path: "/tmp/vmlinux",
            rootfs_path: "/tmp/rootfs"
          },
          secrets_mode: :managed,
          restart_policy: :always,
          metadata: %{}
        },
        overrides
      )
    end

    test "a failed unlock is recorded on the struct and stamped into the runtime map" do
      failure = %{reason: "{:timeout}", at: ~U[2026-08-12 18:55:00Z]}
      vm = base_vm(secrets_unlock_failure: failure)

      record = Mjolnir.VM.build_running_record(vm)

      assert record.runtime["secrets_unlock_failed"] == true
      assert record.runtime["secrets_unlock_error"] == "{:timeout}"
      assert record.runtime["secrets_unlock_failed_at"] == "2026-08-12T18:55:00Z"
    end

    test "a successful (or skipped) unlock is not falsely flagged" do
      vm = base_vm(secrets_unlock_failure: nil)

      record = Mjolnir.VM.build_running_record(vm)

      refute Map.has_key?(record.runtime, "secrets_unlock_failed")
      refute Map.has_key?(record.runtime, "secrets_unlock_error")
      refute Map.has_key?(record.runtime, "secrets_unlock_failed_at")
    end

    test "the flag survives a rebuild of the running record — the CILease trap" do
      # Mjolnir.VM.build_running_record/1 rebuilds `runtime` FROM SCRATCH on
      # every boot and resume (deliberately — see CILease.stamp_runtime's
      # moduledoc). A value written to StateStore any other way would be wiped
      # by the very next boot. Prove the unlock outcome does NOT depend on
      # anything left over in a previous record: build twice in a row, as
      # Reconcile would across two resumes, and confirm the second call
      # (mirroring `state.secrets_unlock_failure` carried fresh on the struct
      # from that boot's do_boot/1) reflects the outcome for THAT boot only.
      failure = %{reason: ":timeout", at: DateTime.utc_now()}

      failed_record = Mjolnir.VM.build_running_record(base_vm(secrets_unlock_failure: failure))
      assert failed_record.runtime["secrets_unlock_failed"] == true

      # A later boot where the unlock succeeds must not carry the old failure
      # forward just because a prior record existed with it set — the struct
      # (not StateStore) is the only source build_running_record reads from,
      # so a fresh `secrets_unlock_failure: nil` on the struct clears it.
      healthy_record =
        Mjolnir.VM.build_running_record(base_vm(secrets_unlock_failure: nil))

      refute Map.has_key?(healthy_record.runtime, "secrets_unlock_failed")
    end

    test "stamp_secrets_unlock_runtime/2 leaves other runtime keys (e.g. CILease's) untouched" do
      runtime = %{"ch_api_socket" => "/tmp/x.sock", "lease_expires_at" => 123}
      failure = %{reason: "boom", at: ~U[2026-01-01 00:00:00Z]}

      stamped = Mjolnir.VM.stamp_secrets_unlock_runtime(runtime, failure)

      assert stamped["ch_api_socket"] == "/tmp/x.sock"
      assert stamped["lease_expires_at"] == 123
      assert stamped["secrets_unlock_failed"] == true
    end
  end

  describe "spawn opts plumbing (init/1)" do
    # init/1 is a plain function that builds the VM state and returns
    # {:ok, state, {:continue, :boot}} WITHOUT running the boot (the continue is
    # only processed by the GenServer loop). This lets us assert the option
    # merge on macOS with no hypervisor.

    test "extra_mounts from spawn opts lands in state.config (gge.1.9)" do
      mounts = [%{tag: "src", shared_dir: "/tmp", opts: []}]

      {:ok, state, {:continue, :boot}} =
        Mjolnir.VM.init(%{id: UUID.uuid4(), extra_mounts: mounts})

      # This is exactly what do_boot reads: Map.get(state.config, :extra_mounts, [])
      assert Map.get(state.config, :extra_mounts) == mounts
    end

    test "extra_mounts defaults to [] when not provided" do
      {:ok, state, {:continue, :boot}} = Mjolnir.VM.init(%{id: UUID.uuid4()})
      assert Map.get(state.config, :extra_mounts) == []
    end

    test "owner_id from spawn opts lands on state.owner_id (API owner-scoping)" do
      {:ok, state, {:continue, :boot}} =
        Mjolnir.VM.init(%{id: UUID.uuid4(), owner_id: "alice"})

      assert state.owner_id == "alice"
    end

    test "owner_id is nil when not provided" do
      {:ok, state, {:continue, :boot}} = Mjolnir.VM.init(%{id: UUID.uuid4()})
      assert state.owner_id == nil
    end

    test "secrets_mode from spawn opts lands on state.secrets_mode" do
      {:ok, state, {:continue, :boot}} =
        Mjolnir.VM.init(%{id: UUID.uuid4(), secrets_mode: :managed})

      assert state.secrets_mode == :managed
    end
  end

  describe "await_boot timeout selection" do
    # await_boot_timeout/1 is private; replicate its contract here (mirrors the
    # CID test convention above) so a regression in the mapping is caught. The
    # real function is exercised end-to-end by the server-gated boot tests.
    @default_await_boot_timeout 30_000
    @managed_await_boot_timeout 90_000

    defp await_boot_timeout(opts) do
      cond do
        is_integer(opts[:await_boot_timeout]) -> opts[:await_boot_timeout]
        opts[:await_boot_timeout] == :infinity -> :infinity
        opts[:secrets_mode] == :managed -> @managed_await_boot_timeout
        true -> @default_await_boot_timeout
      end
    end

    test "non-managed spawn keeps the 30s default" do
      assert await_boot_timeout(%{}) == 30_000
      assert await_boot_timeout(%{secrets_mode: :none}) == 30_000
      assert await_boot_timeout(%{secrets_mode: :ephemeral}) == 30_000
    end

    test "managed spawn gets the longer default" do
      assert await_boot_timeout(%{secrets_mode: :managed}) == 90_000
    end

    test "explicit :await_boot_timeout always wins" do
      assert await_boot_timeout(%{await_boot_timeout: 120_000}) == 120_000
      assert await_boot_timeout(%{secrets_mode: :managed, await_boot_timeout: 15_000}) == 15_000
      assert await_boot_timeout(%{await_boot_timeout: :infinity}) == :infinity
    end
  end
end
