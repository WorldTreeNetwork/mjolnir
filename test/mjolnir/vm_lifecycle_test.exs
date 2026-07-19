defmodule Mjolnir.VMLifecycleTest do
  # Unit tests for the wedge-degradation behaviour added in mjolnir-8ie. No KVM
  # required: a fake GenServer is registered in Mjolnir.VMRegistry to stand in
  # for a VM whose mailbox is blocked on a stuck vsock exec.
  use ExUnit.Case, async: false

  # A stand-in VM GenServer that blocks forever inside handle_call, modelling a
  # mailbox wedged on an :infinity vsock exec after a snapshot pause/resume.
  defmodule WedgedVM do
    use GenServer

    def start_link(vm_id) do
      GenServer.start_link(__MODULE__, vm_id, name: {:via, Registry, {Mjolnir.VMRegistry, vm_id}})
    end

    @impl true
    def init(_vm_id), do: {:ok, %{}}

    @impl true
    def handle_call(_msg, _from, state) do
      # Never returns: the caller's GenServer.call must hit its own timeout.
      Process.sleep(:infinity)
      {:reply, :never, state}
    end
  end

  defp unique_id, do: "wedged-#{System.unique_integer([:positive])}"

  describe "VM.get/1 against a wedged VM" do
    test "returns {:error, :unreachable}, not :not_found" do
      vm_id = unique_id()
      {:ok, _pid} = WedgedVM.start_link(vm_id)

      Application.put_env(:mjolnir, :vm_get_probe_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:mjolnir, :vm_get_probe_timeout_ms) end)

      assert {:error, :unreachable} = Mjolnir.VM.get(vm_id)
    end

    test "still returns :not_found when no VM is registered" do
      assert {:error, :not_found} = Mjolnir.VM.get(unique_id())
    end
  end

  describe "VM.stop/1 against a wedged VM" do
    test "degrades to a forced kill instead of hanging, returning :ok" do
      vm_id = unique_id()
      {:ok, pid} = WedgedVM.start_link(vm_id)

      # Wedge the GenServer: a blocking call keeps it out of its receive loop so
      # a graceful GenServer.stop can never be processed and would hang forever.
      spawn(fn ->
        try do
          GenServer.call(pid, :wedge, 60_000)
        catch
          :exit, _ -> :ok
        end
      end)

      # Give the wedge call time to be picked up into handle_call.
      Process.sleep(50)

      Application.put_env(:mjolnir, :vm_stop_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:mjolnir, :vm_stop_timeout_ms) end)

      # Without the fallback this call would block on GenServer.stop forever.
      assert :ok = Mjolnir.VM.stop(vm_id)
    end

    test "still returns :not_found when no VM is registered" do
      assert {:error, :not_found} = Mjolnir.VM.stop(unique_id())
    end
  end
end
