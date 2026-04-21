defmodule Mjolnir.Chaos.NukeTest do
  @moduledoc """
  `Health.nuke/1` — the L5 "always succeeds at making the VM healthy" lever.

  Sequence:
  1. Spawn a VM and touch a canary file inside it.
  2. `POST /api/vms/:id/nuke` — Health.nuke captures spawn_config, stops
     the VM (full cleanup including subvolume wipe + state delete),
     then spawn_with_id on the same UUID from the base image.
  3. Expect: same UUID, same guest_ip (both derived from UUID so they
     can't change), canary file GONE (fresh BTRFS clone).

  Tagged `:chaos` only — scoped to one VM, no host-wide disruption.
  """

  use ExUnit.Case, async: false

  @moduletag :chaos

  import Mjolnir.Chaos.Helpers

  @tag timeout: 180_000
  test "nuke destroys in-VM state and respawns with same UUID + IP" do
    assert :ok = wait_for_mjolnir_up(30_000)

    {:ok, spawned} = spawn_vm(%{base_image: "arch"})
    vm_id = spawned["id"]
    original_ip = spawned["guest_ip"]
    IO.puts("[chaos:nuke] spawned VM #{vm_id} at #{original_ip}")

    on_exit(fn -> _ = vm_stop(vm_id) end)

    # Drop a canary file inside the guest. If it survives the nuke, the
    # respawn reused the old rootfs — which would be wrong.
    assert {:ok, _} =
             vm_exec(vm_id, "touch /tmp/mjolnir-nuke-canary && ls /tmp/mjolnir-nuke-canary")

    IO.puts("[chaos:nuke] canary set; calling POST /nuke")

    # Nuke blocks on spawn_with_id's :await_boot (up to 30s). After it
    # returns, the new VM should be registered and booted.
    assert {:ok, _} = vm_nuke(vm_id)

    IO.puts("[chaos:nuke] nuke returned; waiting for respawn to be exec-ready")

    # Guest agent readiness is separate from :await_boot, so poll exec
    # until the new agent answers. Budget 60s.
    # Command always returns exit 0 so the API gives us a plain `output` —
    # we parse the token (EXISTS vs MISSING) ourselves.
    {:ok, post_ls} =
      wait_for_exec(vm_id, "test -f /tmp/mjolnir-nuke-canary && echo EXISTS || echo MISSING", 60_000)

    output = String.trim(Map.get(post_ls, "output", ""))

    assert output == "MISSING",
           "canary survived the nuke — respawn reused old rootfs instead of re-cloning: #{inspect(post_ls)}"

    # Same UUID + same IP (both deterministic from UUID).
    assert {:ok, info} = vm_info(vm_id)
    assert info["id"] == vm_id, "UUID should be preserved across nuke"
    assert info["guest_ip"] == original_ip, "guest_ip should be UUID-derived and stable"

    IO.puts("[chaos:nuke] nuke + respawn verified — same UUID, same IP, fresh rootfs")
  end

  # Poll until exec succeeds or timeout. The guest agent may take a few
  # seconds to listen after the VM boots.
  defp wait_for_exec(vm_id, cmd, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_exec(vm_id, cmd, deadline)
  end

  defp do_wait_exec(vm_id, cmd, deadline) do
    case vm_exec(vm_id, cmd) do
      {:ok, result} ->
        {:ok, result}

      {:error, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          do_wait_exec(vm_id, cmd, deadline)
        else
          {:error, :timeout}
        end
    end
  end
end
