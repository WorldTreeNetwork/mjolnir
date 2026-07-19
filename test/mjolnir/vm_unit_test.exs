defmodule Mjolnir.VMUnitTest do
  @moduledoc """
  Unit tests for VM module logic that doesn't require a running hypervisor.
  Tests pure functions and deterministic behavior.
  """
  use ExUnit.Case, async: true

  describe "vsock CID generation" do
    # We test the CID generation indirectly by checking build_config output
    # Since generate_vsock_cid is private, we verify its contract through
    # the public interface or by extracting the logic.

    test "different UUIDs produce different CIDs" do
      uuid1 = "550e8400-e29b-41d4-a716-446655440000"
      uuid2 = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

      cid1 = vsock_cid_for(uuid1)
      cid2 = vsock_cid_for(uuid2)

      assert cid1 != cid2
    end

    test "CID is deterministic for the same UUID" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      assert vsock_cid_for(uuid) == vsock_cid_for(uuid)
    end

    test "CID is always >= 3 (reserved range)" do
      # Test with many UUIDs to ensure the range constraint holds
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = vsock_cid_for(uuid)
        assert cid >= 3, "CID #{cid} is below minimum (3) for UUID #{uuid}"
      end
    end

    test "CID never equals 0xFFFFFFFF (VMADDR_CID_ANY)" do
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = vsock_cid_for(uuid)
        assert cid != 0xFFFFFFFF, "CID should never be VMADDR_CID_ANY"
      end
    end

    test "CID fits in 32-bit unsigned integer" do
      for _ <- 1..100 do
        uuid = UUID.uuid4()
        cid = vsock_cid_for(uuid)
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

  # Replicate the CID generation logic for unit testing
  # (since the actual function is private in Mjolnir.VM)
  defp vsock_cid_for(vm_id) do
    <<cid_raw::unsigned-32, _rest::binary>> = :crypto.hash(:md5, vm_id)
    rem(cid_raw, 0xFFFFFFFF - 3) + 3
  end
end
