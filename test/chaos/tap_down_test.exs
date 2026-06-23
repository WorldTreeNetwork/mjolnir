defmodule Mjolnir.Chaos.TapDownTest do
  @moduledoc """
  Scenario 7: administratively down one VM's host-side TAP interface.

  `ip link set mj-<uuid> down` severs the VM's path to the outside world
  without touching the guest itself — routes stay in place on both sides,
  but packets hit the dead TAP and go nowhere. The L2 `Health.GuestNetwork`
  probe pings 1.1.1.1 (routed via TAP → NAT → enp1s0), so it catches this.

  Heal path (in `VM.handle_call(:reconfigure_network, ...)`):
  host-side `Mjolnir.Network.repair_tap/1` brings the TAP back up and
  re-asserts proxy_arp + /32 route, then guest-side `configure_network`
  re-pushes the addr/default-route (idempotent).

  ## Currently skipped

  Running this test against prod uncovered a cascade failure upstream of
  the probe/heal path:

    1. TAP down → next `exec` over vsock (the probe itself) triggers
       `{:tcp_closed, Port}` on the UDS backing the vsock — the vsock
       GenServer dies with `:connection_closed` mid-`GenServer.call`.
    2. The `VM` GenServer's `call` re-raises the exit. Since the reason
       isn't `:normal`, `preserve_rootfs?/2` keeps state and the
       DynamicSupervisor triggers a restart via Reconcile.
    3. Reconcile calls `Mjolnir.Network.create_tap/1` → `ip tuntap add`,
       which fails with `EBUSY` because the admin-down TAP still exists.
       Boot fails, terminate cleans up the TAP, next Reconcile tick
       eventually recovers.

  Two real bugs on the path: **(a)** exec-over-vsock should be
  insensitive to host-side TAP link state — vsock and TAP are independent
  transports, and the fact that one flaps when the other is admin-down
  means something is cross-linked (possibly CH's reaction to link-carrier
  loss, possibly something in the guest agent). **(b)** `create_tap`
  must be idempotent against a pre-existing interface, or Reconcile's
  resume path needs to call a different primitive (e.g. `repair_tap`)
  when the interface already exists.

  Unskip once both are fixed. See `docs/plans/durability.md` → followups.
  """

  use ExUnit.Case, async: false

  @moduletag :chaos
  @moduletag skip: "blocked on vsock-closes-during-exec + create_tap EBUSY cascade"

  import Mjolnir.Chaos.Helpers

  @tag timeout: 120_000
  test "TAP admin-down is detected by GuestNetwork and healed" do
    assert :ok = wait_for_mjolnir_up(30_000)

    {:ok, spawned} = spawn_vm(%{base_image: "ubuntu-24.04"})
    vm_id = spawned["id"]
    IO.puts("[chaos:tap-down] spawned VM #{vm_id}")

    on_exit(fn -> _ = vm_stop(vm_id) end)

    # Baseline: probe should be :ok — guest can reach 1.1.1.1.
    assert {:ok, baseline} = vm_health(vm_id)

    assert guest_network_state(baseline) == "ok",
           "baseline guest_network not ok: #{inspect(baseline)}"

    IO.puts("[chaos:tap-down] baseline OK; bringing TAP down")
    assert :ok = chaos({:tap_down, vm_id})

    # Probe should flip to :dead within one call (8s timeout upper bound).
    assert {:ok, broken} = vm_health(vm_id)

    assert guest_network_state(broken) == "dead",
           "probe did not detect TAP down: #{inspect(broken)}"

    IO.puts("[chaos:tap-down] detected dead; calling heal")
    assert {:ok, healed} = vm_heal(vm_id, 2)

    assert guest_network_state(healed) == "ok",
           "heal did not restore guest_network: #{inspect(healed)}"

    # Paranoia: confirm the guest actually has egress again via a direct exec.
    assert {:ok, %{"output" => ping}} = vm_exec(vm_id, "ping -c1 -W3 1.1.1.1 2>&1")

    assert String.contains?(ping, "1 received"),
           "guest could not ping 1.1.1.1 after heal: #{ping}"
  end

  defp guest_network_state(%{"checks" => checks}) do
    checks
    |> Enum.find(fn c -> c["name"] == "guest_network" end)
    |> case do
      %{"status" => %{"state" => s}} -> s
      other -> other
    end
  end
end
