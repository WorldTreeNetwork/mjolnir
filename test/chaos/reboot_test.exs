defmodule Mjolnir.Chaos.RebootTest do
  @moduledoc """
  Scenario 3: Server reboot preserves VMs.

  Tagged `:destructive` — this causes ~60s of real host downtime. Skipped by
  default; run with `just chaos-destructive` or `mix test --only chaos
  --include destructive`.

  Same assertion as scenarios 1 and 2: the VM UUID + kernel + rootfs all
  survive a full cold boot, proving that nothing about our durability story
  depends on process-level state that would be lost across reboot.
  """
  use ExUnit.Case, async: false

  @moduletag :chaos
  @moduletag :destructive

  import Mjolnir.Chaos.Helpers

  # Budget: up to 60s spawn + 60s SSH-back + 60s mjolnir-up + 90s VM-rehydrate.
  @tag timeout: 360_000
  test "server reboot preserves VMs" do
    assert :ok = wait_for_mjolnir_up(30_000), "mjolnir not responding before test"

    {:ok, spawned} = spawn_vm(%{base_image: "arch"})
    vm_id = spawned["id"]
    assert is_binary(vm_id)
    IO.puts("[chaos:reboot] spawned VM #{vm_id}")

    on_exit(fn -> _ = vm_stop(vm_id) end)

    assert {:ok, baseline} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:reboot] baseline: #{inspect(baseline)}")

    IO.puts("[chaos:reboot] issuing systemctl reboot — host will be down ~60s")
    assert :ok = chaos(:reboot)

    # Give the reboot a head start so we don't race a still-up SSH daemon.
    Process.sleep(10_000)

    IO.puts("[chaos:reboot] waiting for SSH to come back")
    assert :ok = wait_for_ssh(180_000), "SSH did not come back after reboot"

    IO.puts("[chaos:reboot] SSH back, waiting for mjolnir")
    assert :ok = wait_for_mjolnir_up(60_000), "mjolnir did not start after reboot"

    IO.puts("[chaos:reboot] mjolnir up, waiting for VM rehydration")
    assert {:ok, info} = wait_for_vm(vm_id, 90_000)
    assert info["id"] == vm_id

    assert {:ok, post} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:reboot] post: #{inspect(post)}")

    assert kernel_output(baseline) == kernel_output(post),
           "Kernel version differs after reboot — rootfs was not preserved?"
  end

  defp kernel_output(%{"output" => s}), do: String.trim(s)
  defp kernel_output(%{output: s}), do: String.trim(s)
  defp kernel_output(other), do: inspect(other)
end
