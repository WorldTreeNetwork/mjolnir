defmodule Mjolnir.DormantRegistryTest do
  use ExUnit.Case, async: false

  alias Mjolnir.DormantRegistry

  setup do
    # Clean up any entries registered during each test
    on_exit(fn ->
      for entry <- DormantRegistry.list() do
        DormantRegistry.unregister(entry.vm_id)
      end
    end)

    vm_id = "test-vm-#{:erlang.unique_integer([:positive])}"
    %{vm_id: vm_id}
  end

  describe "register/3 + lookup/1" do
    test "registers a dormant VM and looks it up", %{vm_id: vm_id} do
      config = %{vcpus: 1, memory_mb: 128}
      assert :ok = DormantRegistry.register(vm_id, "snap-1", config)

      assert {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.vm_id == vm_id
      assert entry.snapshot_name == "snap-1"
      assert entry.original_config == config
      assert entry.pending_messages == []
      assert entry.state == :dormant
      assert %DateTime{} = entry.dormant_since
    end
  end

  describe "lookup/1" do
    test "returns :not_found for unknown vm_id" do
      assert :not_found = DormantRegistry.lookup("nonexistent-vm")
    end
  end

  describe "unregister/1" do
    test "removes a dormant VM", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      assert {:ok, _} = DormantRegistry.lookup(vm_id)

      assert :ok = DormantRegistry.unregister(vm_id)
      assert :not_found = DormantRegistry.lookup(vm_id)
    end
  end

  describe "list/0" do
    test "returns empty list initially" do
      assert DormantRegistry.list() == []
    end

    test "returns registered entries", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      entries = DormantRegistry.list()
      assert length(entries) == 1
      assert hd(entries).vm_id == vm_id
    end
  end

  describe "queue_message/3" do
    test "queues a message for a dormant VM", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      assert :ok = DormantRegistry.queue_message(vm_id, "sender-1", %{hello: "world"})

      messages = DormantRegistry.take_pending_messages(vm_id)
      assert [{"sender-1", %{hello: "world"}}] = messages
    end

    test "returns {:error, :not_found} for unknown vm_id" do
      assert {:error, :not_found} = DormantRegistry.queue_message("nonexistent", "s", %{})
    end

    test "returns {:error, :restoring} when VM is restoring", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      DormantRegistry.begin_restore(vm_id)

      assert {:error, :restoring} = DormantRegistry.queue_message(vm_id, "s", %{})
    end
  end

  describe "take_pending_messages/1" do
    test "returns messages in order and clears the queue", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      DormantRegistry.queue_message(vm_id, "s1", :msg1)
      DormantRegistry.queue_message(vm_id, "s2", :msg2)
      DormantRegistry.queue_message(vm_id, "s3", :msg3)

      messages = DormantRegistry.take_pending_messages(vm_id)
      assert [{"s1", :msg1}, {"s2", :msg2}, {"s3", :msg3}] = messages

      # Queue is now empty
      assert [] = DormantRegistry.take_pending_messages(vm_id)
    end

    test "returns empty list for unknown vm_id" do
      assert [] = DormantRegistry.take_pending_messages("nonexistent")
    end
  end

  describe "begin_restore/1" do
    test "transitions :dormant to :restoring", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      assert :ok = DormantRegistry.begin_restore(vm_id)

      {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.state == :restoring
    end

    test "returns :already_restoring if already restoring", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      DormantRegistry.begin_restore(vm_id)

      assert :already_restoring = DormantRegistry.begin_restore(vm_id)
    end

    test "returns {:error, :not_found} for unknown vm_id" do
      assert {:error, :not_found} = DormantRegistry.begin_restore("nonexistent")
    end
  end

  describe "cancel_restore/1" do
    test "transitions :restoring back to :dormant", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{})
      DormantRegistry.begin_restore(vm_id)

      assert :ok = DormantRegistry.cancel_restore(vm_id)

      {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.state == :dormant
    end

    test "is a no-op for unknown vm_id" do
      assert :ok = DormantRegistry.cancel_restore("nonexistent")
    end
  end
end
