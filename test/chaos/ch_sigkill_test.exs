defmodule Mjolnir.Chaos.CHSigkillTest do
  @moduledoc """
  Scenario 4: SIGKILL a VM's cloud-hypervisor process (not mjolnir itself).

  The VM's GenServer receives `{:exit_status, _}` on the hypervisor Port
  and transitions to `:stopped`. Because the terminate reason is
  `{:hypervisor_exit, _}` (not `:normal`), `preserve_rootfs?/2` returns
  `true` — rootfs and state record are preserved.

  The periodic `Mjolnir.Health.Monitor` then spots the stranded state
  record (no registry entry) on its next tick and calls
  `Mjolnir.Reconcile.run/0`, which resumes just this one VM.

  Budget: ~30s Monitor tick + 20s resume = 60s max. Other VMs should be
  untouched throughout.
  """
  use ExUnit.Case, async: false

  @moduletag :chaos

  import Mjolnir.Chaos.Helpers

  @tag timeout: 180_000
  test "SIGKILL on a single CH process self-heals via Monitor" do
    assert :ok = wait_for_mjolnir_up(30_000)

    {:ok, spawned} = spawn_vm(%{base_image: "ubuntu-24.04"})
    vm_id = spawned["id"]
    assert is_binary(vm_id)
    IO.puts("[chaos:ch-sigkill] spawned VM #{vm_id}")

    on_exit(fn -> _ = vm_stop(vm_id) end)

    assert {:ok, baseline} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:ch-sigkill] baseline: #{inspect(baseline)}")

    IO.puts("[chaos:ch-sigkill] SIGKILLing this VM's cloud-hypervisor")
    assert :ok = chaos({:sigkill_ch, vm_id})

    # Wait long enough for:
    # (a) VM GenServer to receive {:exit_status, _} and terminate,
    # (b) Monitor tick (30s interval) to notice the stranded state record,
    # (c) Reconcile.run to resume the VM.
    IO.puts("[chaos:ch-sigkill] waiting for Monitor to self-heal")
    assert {:ok, _info} = wait_for_vm(vm_id, 120_000)

    assert {:ok, post} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:ch-sigkill] post: #{inspect(post)}")

    assert kernel_output(baseline) == kernel_output(post)
  end

  defp kernel_output(%{"output" => s}), do: String.trim(s)
  defp kernel_output(%{output: s}), do: String.trim(s)
  defp kernel_output(other), do: inspect(other)
end
