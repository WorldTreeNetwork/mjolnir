defmodule Mjolnir.DormantRegistryTest do
  use ExUnit.Case, async: false

  alias Mjolnir.DormantRegistry

  setup do
    # Ensure the GenServer is running (a previous test may have stopped it)
    await_registry()

    # Clean up any entries registered during each test
    on_exit(fn ->
      await_registry()

      for entry <- DormantRegistry.list() do
        DormantRegistry.unregister(entry.vm_id)
      end
    end)

    vm_id = "test-vm-#{:erlang.unique_integer([:positive])}"
    %{vm_id: vm_id}
  end

  # Wait for the supervisor to (re)start the DormantRegistry process.
  # After GenServer.stop, the supervisor restarts it asynchronously.
  defp await_registry(attempts \\ 50) do
    case GenServer.whereis(DormantRegistry) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(10)
        await_registry(attempts - 1)

      nil ->
        raise "DormantRegistry did not restart within timeout"
    end
  end

  # Start an isolated DormantRegistry (not the supervised one) for disk tests.
  # Returns the pid. Caller is responsible for stopping it.
  defp start_isolated_registry(name) do
    {:ok, pid} = DormantRegistry.start_link(name: name)
    pid
  end

  describe "register/4 + lookup/1" do
    test "registers a dormant VM and looks it up", %{vm_id: vm_id} do
      config = %{vcpus: 1, memory_mb: 128}
      assert :ok = DormantRegistry.register(vm_id, "snap-1", config, "user-123")

      assert {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.vm_id == vm_id
      assert entry.snapshot_name == "snap-1"
      assert entry.original_config == config
      assert entry.owner_id == "user-123"
      assert entry.pending_messages == []
      assert entry.state == :dormant
      assert %DateTime{} = entry.dormant_since
    end

    test "registers with nil owner_id by default", %{vm_id: vm_id} do
      config = %{vcpus: 1, memory_mb: 128}
      assert :ok = DormantRegistry.register(vm_id, "snap-1", config)

      assert {:ok, entry} = DormantRegistry.lookup(vm_id)
      assert entry.owner_id == nil
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

  describe "owner_id" do
    test "list returns entries with owner_id", %{vm_id: vm_id} do
      DormantRegistry.register(vm_id, "snap-1", %{}, "user-123")
      entries = DormantRegistry.list()
      entry = Enum.find(entries, &(&1.vm_id == vm_id))
      assert entry.owner_id == "user-123"
    end
  end

  describe "disk persistence" do
    setup do
      # Use a temp directory so disk round-trip tests work on macOS
      tmp_dir =
        Path.join(System.tmp_dir!(), "mjolnir_test_#{:erlang.unique_integer([:positive])}")

      original_root = Application.get_env(:mjolnir, :btrfs_root)
      Application.put_env(:mjolnir, :btrfs_root, tmp_dir)

      on_exit(fn ->
        Application.put_env(:mjolnir, :btrfs_root, original_root)
        File.rm_rf(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "round-trips entries through JSON on disk", %{vm_id: vm_id} do
      pid = start_isolated_registry(:disk_rt)
      config = %{vcpus: 2, memory_mb: 256}
      GenServer.call(pid, {:register, vm_id, "snap-rt", config, "user-rt"})
      GenServer.call(pid, :flush_now)

      # Verify file exists and has correct structure
      path = Path.join([Application.get_env(:mjolnir, :btrfs_root), "@dormant", "registry.json"])
      assert File.exists?(path)
      {:ok, content} = File.read(path)
      {:ok, data} = Jason.decode(content)
      assert Map.has_key?(data, vm_id)
      entry_data = data[vm_id]
      assert entry_data["snapshot_name"] == "snap-rt"
      assert entry_data["owner_id"] == "user-rt"
      assert entry_data["original_config"] == %{"vcpus" => 2, "memory_mb" => 256}
      GenServer.stop(pid)
    end

    test "persists pending messages to disk", %{vm_id: vm_id} do
      pid = start_isolated_registry(:disk_msg)
      GenServer.call(pid, {:register, vm_id, "snap-msg", %{}, "user-msg"})
      GenServer.call(pid, {:queue_message, vm_id, "sender-1", %{"data" => "hello"}})
      GenServer.call(pid, {:queue_message, vm_id, "sender-2", %{"data" => "world"}})
      GenServer.call(pid, :flush_now)

      path = Path.join([Application.get_env(:mjolnir, :btrfs_root), "@dormant", "registry.json"])
      {:ok, content} = File.read(path)
      {:ok, data} = Jason.decode(content)
      messages = data[vm_id]["pending_messages"]
      assert length(messages) == 2
      assert Enum.at(messages, 0)["from_vm_id"] == "sender-1"
      assert Enum.at(messages, 0)["payload"] == %{"data" => "hello"}
      assert Enum.at(messages, 1)["from_vm_id"] == "sender-2"
      GenServer.stop(pid)
    end

    test "restores entries from disk on restart", %{vm_id: vm_id} do
      pid1 = start_isolated_registry(:disk_restore1)
      config = %{vcpus: 4, memory_mb: 512}
      GenServer.call(pid1, {:register, vm_id, "snap-restart", config, "user-restart"})
      GenServer.call(pid1, {:queue_message, vm_id, "sender-x", %{"key" => "value"}})
      GenServer.call(pid1, :flush_now)
      GenServer.stop(pid1)

      # Start fresh instance — should load from disk
      pid2 = start_isolated_registry(:disk_restore2)
      {:ok, entry} = GenServer.call(pid2, {:lookup, vm_id})
      assert entry.vm_id == vm_id
      assert entry.snapshot_name == "snap-restart"
      assert entry.owner_id == "user-restart"
      assert entry.state == :dormant
      # Config comes back with string keys from JSON (correct)
      assert entry.original_config == %{"vcpus" => 4, "memory_mb" => 512}
      # Pending messages restored
      assert [{"sender-x", %{"key" => "value"}}] = entry.pending_messages
      GenServer.stop(pid2)
    end

    test "restores multiple entries and preserves message order", %{vm_id: vm_id} do
      vm_id2 = "test-vm-#{:erlang.unique_integer([:positive])}"

      pid1 = start_isolated_registry(:disk_multi1)
      GenServer.call(pid1, {:register, vm_id, "snap-a", %{}, "owner-a"})
      GenServer.call(pid1, {:register, vm_id2, "snap-b", %{}, "owner-b"})
      GenServer.call(pid1, {:queue_message, vm_id, "s1", %{"seq" => 1}})
      GenServer.call(pid1, {:queue_message, vm_id, "s2", %{"seq" => 2}})
      GenServer.call(pid1, {:queue_message, vm_id, "s3", %{"seq" => 3}})
      GenServer.call(pid1, :flush_now)
      GenServer.stop(pid1)

      pid2 = start_isolated_registry(:disk_multi2)
      {:ok, entry_a} = GenServer.call(pid2, {:lookup, vm_id})
      {:ok, entry_b} = GenServer.call(pid2, {:lookup, vm_id2})
      assert entry_a.owner_id == "owner-a"
      assert entry_b.owner_id == "owner-b"
      # Message order preserved
      assert [{"s1", %{"seq" => 1}}, {"s2", %{"seq" => 2}}, {"s3", %{"seq" => 3}}] =
               entry_a.pending_messages

      GenServer.stop(pid2)
    end

    test "handles missing registry file gracefully" do
      # tmp_dir has no file yet
      pid = start_isolated_registry(:disk_missing)
      assert GenServer.call(pid, :list) == []
      GenServer.stop(pid)
    end

    test "handles corrupted registry file gracefully" do
      path = Path.join([Application.get_env(:mjolnir, :btrfs_root), "@dormant", "registry.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not valid json {{{")

      pid = start_isolated_registry(:disk_corrupt)
      assert GenServer.call(pid, :list) == []
      GenServer.stop(pid)
    end

    test "terminate flushes dirty state to disk", %{vm_id: vm_id} do
      pid = start_isolated_registry(:disk_terminate)
      GenServer.call(pid, {:register, vm_id, "snap-term", %{vcpus: 1}, "user-term"})

      # Stop without calling flush_now — terminate should flush
      GenServer.stop(pid)

      path = Path.join([Application.get_env(:mjolnir, :btrfs_root), "@dormant", "registry.json"])
      assert File.exists?(path)

      # Restart and verify data survived
      pid2 = start_isolated_registry(:disk_terminate2)
      {:ok, entry} = GenServer.call(pid2, {:lookup, vm_id})
      assert entry.snapshot_name == "snap-term"
      assert entry.owner_id == "user-term"
      GenServer.stop(pid2)
    end

    test "restoring state always resets to :dormant", %{vm_id: vm_id} do
      pid1 = start_isolated_registry(:disk_state1)
      GenServer.call(pid1, {:register, vm_id, "snap-state", %{}, "user-state"})
      GenServer.call(pid1, {:begin_restore, vm_id})
      {:ok, entry} = GenServer.call(pid1, {:lookup, vm_id})
      assert entry.state == :restoring
      GenServer.call(pid1, :flush_now)
      GenServer.stop(pid1)

      # After restart, :restoring should reset to :dormant
      pid2 = start_isolated_registry(:disk_state2)
      {:ok, entry} = GenServer.call(pid2, {:lookup, vm_id})
      assert entry.state == :dormant
      GenServer.stop(pid2)
    end
  end
end
