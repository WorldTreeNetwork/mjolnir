defmodule Mjolnir.Chaos.NatWipeTest do
  @moduledoc """
  Scenario 8: `iptables -t nat -F` wipes every NAT rule — including our
  MASQUERADE for the VM subnet. With the rule gone, guests can still talk
  to each other (FORWARD rules are on the filter table, not nat), but any
  packet destined for the internet leaves the host with a 10.x source and
  gets dropped upstream. This is the failure mode that silently broke
  inference for weeks before we built the probe/heal framework.

  Assertions:
  1. `GET /health/host` reports `nat_masquerade = :ok` in baseline.
  2. After `iptables -t nat -F`, the check flips to `:dead`.
  3. `POST /health/host/heal` restores the rule; re-check is `:ok`.
  4. A live VM can still reach the internet after heal.

  Tagged `:destructive` because the wipe breaks egress for *every* VM on
  the host during the test window (typically <5s between flush and heal).
  """

  use ExUnit.Case, async: false

  @moduletag :chaos
  @moduletag :destructive

  import Mjolnir.Chaos.Helpers

  @tag timeout: 120_000
  test "NAT wipe is detected and self-heals via host heal endpoint" do
    assert :ok = wait_for_mjolnir_up(30_000)

    # Baseline: NAT rule should be present.
    assert {:ok, baseline} = host_health()
    assert nat_status(baseline) == "ok",
           "expected baseline nat_masquerade = ok, got #{inspect(nat_status(baseline))}"

    IO.puts("[chaos:nat-wipe] baseline OK; flushing iptables nat table")
    assert :ok = chaos(:flush_nat)

    # Probe should notice immediately — no buffering here, it reads
    # iptables live every call.
    assert {:ok, wiped} = host_health()

    assert nat_status(wiped) == "dead",
           "expected nat_masquerade = dead after flush, got #{inspect(wiped)}"

    IO.puts("[chaos:nat-wipe] wipe detected; triggering host heal")
    assert {:ok, healed} = host_heal()
    assert nat_status(healed) == "ok", "heal did not restore NAT: #{inspect(healed)}"

    # End-to-end: pick an existing running VM (if any) and verify egress.
    # If no VMs are running, skip this leg — the health check is the load-
    # bearing assertion.
    case vm_list() do
      {:ok, %{"vms" => [%{"id" => vm_id} | _]}} ->
        IO.puts("[chaos:nat-wipe] verifying live egress from VM #{vm_id}")

        # Short ping to a well-known IP; anything under 5s is a win.
        assert {:ok, %{"output" => out}} =
                 vm_exec(vm_id, "ping -c1 -W3 1.1.1.1 2>&1")

        assert String.contains?(out, "1 received"),
               "guest could not ping 1.1.1.1 after heal: #{out}"

      _ ->
        IO.puts("[chaos:nat-wipe] no live VMs — skipping egress leg")
    end
  end

  defp nat_status(%{"checks" => checks}) do
    # encode_health_status/1 in the router wraps atoms into a map:
    #   :ok -> %{"state" => "ok"}
    #   {:dead, reason} -> %{"state" => "dead", "reason" => inspect(reason)}
    checks
    |> Enum.find(fn c -> c["name"] == "nat_masquerade" end)
    |> case do
      %{"status" => %{"state" => s}} -> s
      other -> other
    end
  end
end
