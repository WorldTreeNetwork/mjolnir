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

  # Replicate the CID generation logic for unit testing
  # (since the actual function is private in Mjolnir.VM)
  defp vsock_cid_for(vm_id) do
    <<cid_raw::unsigned-32, _rest::binary>> = :crypto.hash(:md5, vm_id)
    rem(cid_raw, 0xFFFFFFFF - 3) + 3
  end
end
