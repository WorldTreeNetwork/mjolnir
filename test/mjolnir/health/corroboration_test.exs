defmodule Mjolnir.Health.CorroborationTest do
  @moduledoc """
  Unit tests for the `:dead` corroboration step in `Mjolnir.Health` — the fix
  for false "DEAD" verdicts when only the vsock guest-agent channel is wedged.
  Exercises `corroborated_overall/3` directly with an injected liveness probe,
  so no real VM, vsock, or socket is involved.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Health

  defp vm, do: struct!(%Mjolnir.VM{id: "vm-1"}, net_config: %{guest_ip: "10.200.0.9"})

  defp liveness(result), do: [liveness: fn _vm, _opts -> result end]

  describe "corroborated_overall/3 — only :dead is corroborated" do
    test ":dead + TCP :alive => downgraded to :agent_unreachable" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:alive)) == :agent_unreachable
    end

    test ":dead + TCP :unreachable => stays :dead" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:unreachable)) == :dead
    end

    test ":dead + TCP :unknown (no corroboration possible) => stays :dead" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:unknown)) == :dead
    end

    test ":ok passes through without probing liveness" do
      exploding = [liveness: fn _vm, _opts -> flunk("liveness must not run for :ok") end]
      assert Health.corroborated_overall(:ok, vm(), exploding) == :ok
    end

    test ":degraded passes through without probing liveness" do
      exploding = [liveness: fn _vm, _opts -> flunk("liveness must not run for :degraded") end]
      assert Health.corroborated_overall(:degraded, vm(), exploding) == :degraded
    end
  end

  # mjolnir-nf6: a live agent must never be reported as unreachable.
  describe "corroborated_overall/4 — agent-channel evidence outranks the roll-up" do
    defp check(name, status), do: %{level: 0, name: name, status: status}

    defp agent_ok do
      [check("guest_agent_ping", :ok), check("vsock_connection", :ok)]
    end

    test "agent checks :ok + a dead higher-level check => :degraded, liveness never probed" do
      # This is the 2026-07-21 production case: vsock provably fine, only the
      # L2 network probe dead. Claiming :agent_unreachable here is what sent a
      # whole debugging session after a nonexistent vsock bug.
      checks = agent_ok() ++ [check("guest_network", {:dead, :egress_blocked})]
      exploding = [liveness: fn _vm, _opts -> flunk("agent answered; liveness is irrelevant") end]

      assert Health.corroborated_overall(:dead, checks, vm(), exploding) == :degraded
    end

    test "agent ping dead + TCP alive => still :agent_unreachable" do
      checks = [
        check("guest_agent_ping", {:dead, :timeout}),
        check("vsock_connection", {:dead, :timeout})
      ]

      assert Health.corroborated_overall(:dead, checks, vm(), liveness(:alive)) ==
               :agent_unreachable
    end

    test "agent ping dead + TCP unreachable => :dead" do
      checks = [check("guest_agent_ping", {:dead, :timeout})]
      assert Health.corroborated_overall(:dead, checks, vm(), liveness(:unreachable)) == :dead
    end

    test "ping ok but the persistent vsock is down is healable without a TCP proof" do
      # The dev-VM failure: one-shot ping answers, vsock_conn is nil, and there
      # is no guest_ip so TCP liveness is :unknown. Staying :dead made the
      # monitor refuse the L1 rebuild on every tick.
      checks = [
        check("guest_agent_ping", :ok),
        check("vsock_connection", {:dead, :no_vsock_conn}),
        check("guest_network", {:dead, :no_net_config})
      ]

      exploding = [liveness: fn _vm, _opts -> flunk("one-shot ping is the proof of life") end]

      assert Health.corroborated_overall(:dead, checks, vm(), exploding) == :agent_unreachable
    end

    test "empty check list keeps the conservative 3-arity behavior" do
      assert Health.corroborated_overall(:dead, [], vm(), liveness(:alive)) == :agent_unreachable
    end
  end

  describe "failing_check_names/1" do
    test "lists only the failing checks, with their reasons" do
      checks = [
        %{level: 0, name: "guest_agent_ping", status: :ok},
        %{level: 2, name: "guest_network", status: {:dead, :egress_blocked}}
      ]

      assert Health.failing_check_names(checks) == ["guest_network={:dead, :egress_blocked}"]
    end
  end
end
