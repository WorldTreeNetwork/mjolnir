defmodule Mjolnir.EventBusTest do
  use ExUnit.Case, async: true

  alias Mjolnir.EventBus

  setup do
    # Ensure :pg scope is started for tests
    case :pg.start_link(EventBus.pg_scope()) do
      {:ok, pid} ->
        on_exit(fn -> Process.exit(pid, :normal) end)
        :ok

      {:error, {:already_started, _}} ->
        :ok
    end

    :ok
  end

  describe "subscribe/1" do
    test "subscribes to events for a specific VM" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      EventBus.subscribe(vm_id)
      EventBus.publish(vm_id, :vm_spawned, %{vcpus: 2})

      assert_receive {:mjolnir_event, ^vm_id, :vm_spawned, %{vcpus: 2}}
    end

    test "does not receive events for other VMs" do
      vm_a = "test-vm-a-#{System.unique_integer([:positive])}"
      vm_b = "test-vm-b-#{System.unique_integer([:positive])}"

      EventBus.subscribe(vm_a)
      EventBus.publish(vm_b, :vm_spawned, %{})

      refute_receive {:mjolnir_event, ^vm_b, :vm_spawned, _}, 50
    end
  end

  describe "subscribe(:all)" do
    test "receives events for all VMs" do
      vm_a = "test-vm-a-#{System.unique_integer([:positive])}"
      vm_b = "test-vm-b-#{System.unique_integer([:positive])}"

      EventBus.subscribe(:all)

      EventBus.publish(vm_a, :vm_spawned, %{vcpus: 2})
      EventBus.publish(vm_b, :vm_stopped, %{})

      assert_receive {:mjolnir_event, ^vm_a, :vm_spawned, %{vcpus: 2}}
      assert_receive {:mjolnir_event, ^vm_b, :vm_stopped, %{}}
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events for a specific VM" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      EventBus.subscribe(vm_id)
      EventBus.publish(vm_id, :vm_spawned, %{})
      assert_receive {:mjolnir_event, ^vm_id, :vm_spawned, _}

      EventBus.unsubscribe(vm_id)
      EventBus.publish(vm_id, :vm_stopped, %{})
      refute_receive {:mjolnir_event, ^vm_id, :vm_stopped, _}, 50
    end
  end

  describe "unsubscribe(:all)" do
    test "stops receiving all events" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      EventBus.subscribe(:all)
      EventBus.publish(vm_id, :vm_spawned, %{})
      assert_receive {:mjolnir_event, ^vm_id, :vm_spawned, _}

      EventBus.unsubscribe(:all)
      EventBus.publish(vm_id, :vm_stopped, %{})
      refute_receive {:mjolnir_event, ^vm_id, :vm_stopped, _}, 50
    end
  end

  describe "publish/3" do
    test "delivers to multiple subscribers of the same VM" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      # Spawn two subscriber processes
      parent = self()

      subscriber1 =
        spawn(fn ->
          EventBus.subscribe(vm_id)
          send(parent, {:ready, 1})

          receive do
            {:mjolnir_event, ^vm_id, :vm_spawned, payload} ->
              send(parent, {:received, 1, payload})
          end
        end)

      subscriber2 =
        spawn(fn ->
          EventBus.subscribe(vm_id)
          send(parent, {:ready, 2})

          receive do
            {:mjolnir_event, ^vm_id, :vm_spawned, payload} ->
              send(parent, {:received, 2, payload})
          end
        end)

      # Wait for both to subscribe
      assert_receive {:ready, 1}
      assert_receive {:ready, 2}

      # Publish event
      payload = %{vcpus: 4, memory_mb: 1024}
      EventBus.publish(vm_id, :vm_spawned, payload)

      # Both should receive
      assert_receive {:received, 1, ^payload}
      assert_receive {:received, 2, ^payload}

      # Cleanup
      Process.exit(subscriber1, :normal)
      Process.exit(subscriber2, :normal)
    end

    test "delivers to both VM-specific and :all subscribers" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      parent = self()

      # VM-specific subscriber
      vm_subscriber =
        spawn(fn ->
          EventBus.subscribe(vm_id)
          send(parent, {:ready, :vm})

          receive do
            {:mjolnir_event, ^vm_id, :vm_spawned, payload} ->
              send(parent, {:received, :vm, payload})
          end
        end)

      # :all subscriber
      all_subscriber =
        spawn(fn ->
          EventBus.subscribe(:all)
          send(parent, {:ready, :all})

          receive do
            {:mjolnir_event, ^vm_id, :vm_spawned, payload} ->
              send(parent, {:received, :all, payload})
          end
        end)

      # Wait for both to subscribe
      assert_receive {:ready, :vm}
      assert_receive {:ready, :all}

      # Publish event
      payload = %{vcpus: 2}
      EventBus.publish(vm_id, :vm_spawned, payload)

      # Both should receive
      assert_receive {:received, :vm, ^payload}
      assert_receive {:received, :all, ^payload}

      # Cleanup
      Process.exit(vm_subscriber, :normal)
      Process.exit(all_subscriber, :normal)
    end

    test "supports all documented event types" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      EventBus.subscribe(vm_id)

      # Test each event type
      EventBus.publish(vm_id, :vm_spawned, %{})
      assert_receive {:mjolnir_event, ^vm_id, :vm_spawned, %{}}

      EventBus.publish(vm_id, :vm_stopped, %{})
      assert_receive {:mjolnir_event, ^vm_id, :vm_stopped, %{}}

      EventBus.publish(vm_id, :snapshot_created, %{snapshot_id: "snap123"})
      assert_receive {:mjolnir_event, ^vm_id, :snapshot_created, %{snapshot_id: "snap123"}}

      EventBus.publish(vm_id, :agent_event, %{type: "custom", data: "value"})
      assert_receive {:mjolnir_event, ^vm_id, :agent_event, %{type: "custom", data: "value"}}
    end

    test "defaults payload to empty map" do
      vm_id = "test-vm-#{System.unique_integer([:positive])}"

      EventBus.subscribe(vm_id)
      EventBus.publish(vm_id, :vm_spawned)

      assert_receive {:mjolnir_event, ^vm_id, :vm_spawned, %{}}
    end
  end
end
