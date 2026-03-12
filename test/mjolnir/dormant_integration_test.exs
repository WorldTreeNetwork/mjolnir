defmodule Mjolnir.DormantIntegrationTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{DormantRegistry, VM, VMRegistry}

  @moduletag :integration
  @moduletag :snapshot

  setup do
    on_exit(fn ->
      for vm <- VM.list() do
        VM.stop(vm.id)
      end
    end)

    :ok
  end

  @tag timeout: 120_000
  test "dormant lifecycle: spawn -> done -> restore on message" do
    # 1. Spawn a VM
    {:ok, vm_id} = VM.spawn()
    unique = :erlang.unique_integer([:positive])
    marker = "marker-#{unique}"

    # 2. Write a state marker into the VM
    {:ok, _output} = VM.exec(vm_id, "echo #{marker} > /tmp/marker", timeout: 10_000)

    # 3. Signal done — triggers snapshot + dormant
    :ok = VM.handle_done(vm_id)

    # 4. Verify VM is in DormantRegistry
    assert {:ok, entry} = DormantRegistry.lookup(vm_id)
    assert entry.snapshot_name != nil
    assert entry.state == :dormant

    # 5. Verify VM is no longer in VMRegistry (GenServer exited)
    assert Registry.lookup(VMRegistry, vm_id) == []

    # 6. Deliver a message to trigger restore
    :ok = VM.deliver_message(vm_id, "test", %{wake: true})

    # 7. Poll until vm_id reappears in VMRegistry (restore is async via Task)
    poll_until(
      fn ->
        Registry.lookup(VMRegistry, vm_id) != []
      end, timeout: 60_000, interval: 500)

    # 8. Verify state was preserved through snapshot
    {:ok, output} = VM.exec(vm_id, "cat /tmp/marker", timeout: 10_000)
    assert String.contains?(output, marker)

    # 9. Verify DormantRegistry entry was cleaned up
    assert :not_found = DormantRegistry.lookup(vm_id)

    # 10. Cleanup
    VM.stop(vm_id)
  end

  defp poll_until(fun, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    interval = Keyword.get(opts, :interval, 500)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll(fun, interval, deadline)
  end

  defp do_poll(fun, interval, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for condition")
      else
        Process.sleep(interval)
        do_poll(fun, interval, deadline)
      end
    end
  end
end
