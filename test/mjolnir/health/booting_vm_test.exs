defmodule Mjolnir.Health.BootingVMTest do
  # mjolnir-y32: a VM that has not finished booting is not a sick VM.
  #
  # This state only became observable when the managed-secrets unlock moved off
  # the VM process. Before that, do_boot ran the unlock inline with a 60s vsock
  # bound, so the mailbox was shut for the whole window and Health.Monitor's
  # probe timed out — reporting `GenServer unreachable` for a perfectly healthy
  # VM on every single deploy, which is exactly when an operator is watching.
  #
  # Now the process answers during that window, and answers honestly: :booting.
  # The verdict has to be treated like :busy — the probes fail because the VM
  # is mid-boot, and the L1 heal would stop the very Vsock.Connection the
  # unlock is using. Same category error as mjolnir-1s9, different cause.
  use ExUnit.Case, async: true

  alias Mjolnir.Health

  defp vm(state) do
    %Mjolnir.VM{id: "vm-#{System.unique_integer([:positive])}", state: state}
  end

  defp checks(status) do
    [
      %{level: 0, name: "guest_agent_ping", status: status},
      %{level: 1, name: "vsock_connection", status: status}
    ]
  end

  describe "booting?/1" do
    test "true only while the VM is :booting" do
      assert Health.booting?(vm(:booting))
      refute Health.booting?(vm(:running))
      refute Health.booting?(vm(:stopped))
      refute Health.booting?(vm(:unreachable))
    end

    test "a VM struct with no state set is not booting" do
      # Fixtures and structs rebuilt from older records must not become
      # silently unhealable.
      refute Health.booting?(%Mjolnir.VM{id: "bare"})
    end
  end

  describe "corroborated_overall/4" do
    test ":dead becomes :booting while the VM is coming up" do
      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), vm(:booting), []) ==
               :booting
    end

    test ":degraded becomes :booting too — healing on it does the same damage" do
      assert Health.corroborated_overall(:degraded, checks({:degraded, :slow}), vm(:booting), []) ==
               :booting
    end

    test "booting short-circuits BEFORE the TCP liveness probe" do
      liveness = fn _vm, _opts -> flunk("liveness must not be consulted for a booting VM") end

      assert Health.corroborated_overall(
               :dead,
               checks({:dead, :timeout}),
               vm(:booting),
               liveness: liveness
             ) == :booting
    end

    test ":ok is never rewritten" do
      assert Health.corroborated_overall(:ok, checks(:ok), vm(:booting), []) == :ok
    end

    test "a RUNNING VM keeps the old verdicts exactly" do
      # The guard must not blunt genuine death detection once boot is over.
      running = vm(:running)

      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), running,
               liveness: fn _, _ -> :unreachable end
             ) == :dead

      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), running,
               liveness: fn _, _ -> :alive end
             ) == :agent_unreachable

      assert Health.corroborated_overall(:degraded, checks({:degraded, :x}), running, []) ==
               :degraded
    end

    test "busy still wins over booting — an exec is stronger proof of life" do
      mid_boot_exec = %{vm(:booting) | exec_inflight: %{make_ref() => "cryptsetup"}}

      assert Health.corroborated_overall(:dead, checks({:dead, :timeout}), mid_boot_exec, []) ==
               :busy
    end
  end
end
