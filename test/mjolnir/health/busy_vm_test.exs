defmodule Mjolnir.Health.BusyVMTest do
  # mjolnir-1s9: Mjolnir's health system was destroying its own long-running
  # operations.
  #
  # A guest busy with a long command answers probes slowly — a `cp -a` of 139MB
  # plus a bundler saturates 2 vCPUs. Health.Monitor read that as unreachable and
  # healed the VM, and the L1 heal stops the very Vsock.Connection the in-flight
  # exec is blocked on. The exec's GenServer.call then exits :normal, surfacing
  # as {:vsock_unavailable, ...}. Reproduced 100% of the time on deploy builds,
  # on exactly the one step long enough to trip the probe.
  #
  # The category error: BUSY read as DEAD. An exec WE dispatched is the strongest
  # possible proof of life — the guest accepted a command and has not returned.
  use ExUnit.Case, async: true

  alias Mjolnir.Health

  defp vm(opts \\ []) do
    %Mjolnir.VM{
      id: "vm-#{System.unique_integer([:positive])}",
      exec_inflight: Keyword.get(opts, :inflight, %{})
    }
  end

  defp busy_vm, do: vm(inflight: %{make_ref() => "bun run build"})

  defp checks(status) do
    [
      %{level: 0, name: "guest_agent_ping", status: status},
      %{level: 1, name: "vsock_connection", status: status}
    ]
  end

  describe "busy?/1" do
    test "false for an idle VM, true while an exec is in flight" do
      refute Health.busy?(vm())
      assert Health.busy?(busy_vm())
    end

    test "several concurrent execs still read as busy" do
      assert Health.busy?(vm(inflight: %{make_ref() => "a", make_ref() => "b"}))
    end
  end

  describe "corroborated_overall/4 — the fix" do
    test ":dead becomes :busy when an exec is in flight" do
      # This is the exact path that killed deploy builds: both agent-channel
      # probes time out under build load, the roll-up says :dead, and the
      # Monitor heals — severing the exec.
      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), busy_vm(), []) ==
               :busy
    end

    test ":degraded also becomes :busy — healing on it does the same damage" do
      assert Health.corroborated_overall(:degraded, checks({:degraded, :slow}), busy_vm(), []) ==
               :busy
    end

    test "busy short-circuits BEFORE the TCP liveness probe" do
      # An exec in flight is stronger evidence than a TCP SYN-ACK, and the probe
      # costs a network round trip per tick.
      liveness = fn _vm, _opts -> flunk("liveness must not be consulted for a busy VM") end

      assert Health.corroborated_overall(
               :dead,
               checks({:dead, :timeout}),
               busy_vm(),
               liveness: liveness
             ) == :busy
    end

    test "an IDLE VM keeps the old verdicts exactly" do
      # The fix must not blunt genuine death detection.
      idle = vm()

      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), idle,
               liveness: fn _, _ -> :unreachable end
             ) == :dead

      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), idle,
               liveness: fn _, _ -> :alive end
             ) == :agent_unreachable

      assert Health.corroborated_overall(:dead, checks(:ok), idle, []) == :degraded

      assert Health.corroborated_overall(:degraded, checks({:degraded, :x}), idle, []) ==
               :degraded
    end

    test ":ok is never rewritten, busy or not" do
      assert Health.corroborated_overall(:ok, checks(:ok), busy_vm(), []) == :ok
      assert Health.corroborated_overall(:ok, checks(:ok), vm(), []) == :ok
    end

    test "a VM struct without the field is treated as idle, not busy" do
      # Structs rebuilt from older records must not silently become unhealable.
      stale = Map.delete(vm(), :exec_inflight)
      refute Health.busy?(stale)
    end
  end
end
