defmodule Mjolnir.Chaos.SigkillBeamTest do
  @moduledoc """
  Scenario 2: `pkill -9 beam.smp` preserves VMs.

  SIGKILL on mjolnir's BEAM process. systemd's `Restart=always` brings
  mjolnir back, and `Mjolnir.Reconcile` rehydrates VMs from StateStore.

  Unlike scenario 1 (graceful `systemctl restart`), this path doesn't run
  `ExecStop` or VM terminate callbacks at all — the whole cgroup dies
  instantly. The rootfs subvolume survives because nobody had time to
  destroy it. Should be noticeably faster end-to-end than scenario 1
  (no 30s TimeoutStopSec).
  """
  use ExUnit.Case, async: false

  @moduletag :chaos

  import Mjolnir.Chaos.Helpers

  @tag timeout: 180_000
  test "SIGKILL on beam.smp preserves VMs" do
    assert :ok = wait_for_mjolnir_up(30_000), "mjolnir not responding before test"

    {:ok, spawned} = spawn_vm(%{base_image: "ubuntu-24.04"})
    vm_id = spawned["id"]
    assert is_binary(vm_id)
    IO.puts("[chaos:sigkill] spawned VM #{vm_id}")

    on_exit(fn -> _ = vm_stop(vm_id) end)

    assert {:ok, baseline} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:sigkill] baseline: #{inspect(baseline)}")

    IO.puts("[chaos:sigkill] SIGKILLing beam.smp")
    assert :ok = chaos(:sigkill_beam)

    assert :ok = wait_for_mjolnir_up(60_000), "mjolnir did not come back after SIGKILL"
    IO.puts("[chaos:sigkill] mjolnir back, waiting for rehydration")

    assert {:ok, info} = wait_for_vm(vm_id, 90_000)
    assert info["id"] == vm_id

    assert {:ok, post} = vm_exec(vm_id, "uname -r")
    IO.puts("[chaos:sigkill] post: #{inspect(post)}")

    assert kernel_output(baseline) == kernel_output(post),
           "Kernel version differs after SIGKILL — rootfs was not preserved?"
  end

  defp kernel_output(%{"output" => s}), do: String.trim(s)
  defp kernel_output(%{output: s}), do: String.trim(s)
  defp kernel_output(other), do: inspect(other)
end
