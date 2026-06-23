defmodule Mjolnir.Chaos.RestartTest do
  @moduledoc """
  Scenario 1: `systemctl restart mjolnir` preserves VMs.

  Runs against a live server (MJOLNIR_HOST). Spawns a fresh VM, restarts the
  mjolnir service, and asserts the same VM UUID reappears and exec still
  works afterwards.

  This test is excluded by default. Run with:

      just chaos                 # runs :chaos tag, skips :destructive
      just chaos-restart         # runs just this file
  """
  use ExUnit.Case, async: false

  @moduletag :chaos

  import Mjolnir.Chaos.Helpers

  @tag timeout: 180_000
  test "mjolnir restart preserves VMs" do
    # 1. Baseline: mjolnir is up
    assert :ok = wait_for_mjolnir_up(30_000), "mjolnir not responding to /health before test"

    # 2. Spawn a fresh VM, remember its UUID
    {:ok, spawned} = spawn_vm(%{base_image: "ubuntu-24.04"})
    vm_id = spawned["id"] || spawned[:id]
    assert is_binary(vm_id), "spawn response missing id: #{inspect(spawned)}"

    IO.puts("[chaos:restart] spawned VM #{vm_id}")

    on_exit(fn ->
      # Best-effort cleanup — don't fail the test on cleanup errors
      _ = vm_stop(vm_id)
    end)

    # 3. Baseline exec — prove the VM is responsive
    assert {:ok, baseline} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:restart] baseline uname -r: #{inspect(baseline)}")

    # 4. INDUCE CHAOS: restart mjolnir
    IO.puts("[chaos:restart] restarting mjolnir service")
    assert :ok = chaos(:restart_mjolnir)

    # 5. Wait for mjolnir to come back
    assert :ok = wait_for_mjolnir_up(60_000), "mjolnir did not come back after restart"
    IO.puts("[chaos:restart] mjolnir back up, waiting for VM rehydration")

    # 6. Wait for Reconcile to rehydrate our VM
    assert {:ok, info} = wait_for_vm(vm_id, 90_000)
    assert (info["id"] || info[:id]) == vm_id

    # 7. Post-chaos exec — prove the VM is still responsive
    assert {:ok, post} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:restart] post-chaos uname -r: #{inspect(post)}")

    # Kernel version should be identical (same rootfs)
    assert kernel_output(baseline) == kernel_output(post),
           "Kernel version differs after restart — did the rootfs get re-cloned?"
  end

  defp kernel_output(%{"output" => s}), do: String.trim(s)
  defp kernel_output(%{output: s}), do: String.trim(s)
  defp kernel_output(other), do: inspect(other)
end
