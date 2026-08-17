defmodule Mjolnir.AdmitTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{Admit, DormantRegistry, VM}

  describe "dormancy_reason/1" do
    test "persistent secrets refuse" do
      assert Admit.dormancy_reason(%{secrets_mode: :persistent, restart_policy: :always}) ==
               {:error, :secrets_prevent_dormancy}
    end

    test "restart_policy never refuses (add-buzz-local-client)" do
      assert Admit.dormancy_reason(%{secrets_mode: :none, restart_policy: :never}) ==
               {:error, :never_prevents_dormancy}
    end

    test "always + non-persistent may go dormant" do
      assert Admit.dormancy_reason(%{secrets_mode: :none, restart_policy: :always}) == :ok
      assert Admit.dormancy_reason(%{secrets_mode: :ephemeral, restart_policy: :always}) == :ok
    end

    test "persistent wins over never" do
      assert Admit.dormancy_reason(%{secrets_mode: :persistent, restart_policy: :never}) ==
               {:error, :secrets_prevent_dormancy}
    end
  end

  describe "thaw_allowed?/2" do
    test "missing attestation is deny" do
      refute Admit.thaw_allowed?("vm-1", %{wake: true})
      refute Admit.thaw_allowed?("vm-1", "not a map")
      refute Admit.thaw_allowed?("vm-1", nil)
    end

    test "mismatched vm_id is deny" do
      refute Admit.thaw_allowed?("vm-1", %{
               "attestation" => %{"vm_id" => "other", "epoch" => 0}
             })
    end

    test "non-integer epoch is deny" do
      refute Admit.thaw_allowed?("vm-1", %{
               "attestation" => %{"vm_id" => "vm-1", "epoch" => "0"}
             })
    end

    test "matching vm_id and epoch is allow (v1 shape check)" do
      assert Admit.thaw_allowed?("vm-1", %{
               "attestation" => %{"vm_id" => "vm-1", "epoch" => 0}
             })

      assert Admit.thaw_allowed?("vm-1", %{
               attestation: %{vm_id: "vm-1", epoch: 3}
             })
    end
  end

  describe "deliver_message/3 fail-closed thaw" do
    setup do
      vm_id = "admit-#{System.unique_integer([:positive])}"
      :ok = DormantRegistry.register(vm_id, "snap-admit", %{})
      on_exit(fn -> DormantRegistry.unregister(vm_id) end)
      %{vm_id: vm_id}
    end

    test "unattested payload does not queue or restore", %{vm_id: vm_id} do
      assert {:error, :admission_denied} = VM.deliver_message(vm_id, "external", %{wake: true})
      assert [] = DormantRegistry.take_pending_messages(vm_id)
      assert {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.state == :dormant
    end

    test "wrong-vm attestation does not queue", %{vm_id: vm_id} do
      payload = %{"attestation" => %{"vm_id" => "nope", "epoch" => 0}}
      assert {:error, :admission_denied} = VM.deliver_message(vm_id, "external", payload)
      assert [] = DormantRegistry.take_pending_messages(vm_id)
    end
  end
end
