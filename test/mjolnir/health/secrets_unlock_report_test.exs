defmodule Mjolnir.Health.SecretsUnlockReportTest do
  @moduledoc """
  Unit tests for mjolnir-3v2: `Mjolnir.Health.secrets_unlock_report/1` exposes
  a failed managed-secrets unlock as INFORMATION on the health report, without
  affecting `overall`/`checks` — see the moduledoc note at its call site in
  `Mjolnir.Health.check/1` for why it must not drive Health.Monitor's
  auto-heal (mjolnir-1s9: healing a VM the heal path can't actually fix is
  its own bug). Exercised directly against a hand-built VM struct, the same
  way `corroborated_overall/3` is tested in corroboration_test.exs.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Health

  test "nil secrets_unlock_failure => no report" do
    vm = %Mjolnir.VM{id: "vm-1", secrets_unlock_failure: nil}
    assert Health.secrets_unlock_report(vm) == nil
  end

  test "a failure is surfaced with reason and an ISO8601 timestamp" do
    vm = %Mjolnir.VM{
      id: "vm-1",
      secrets_unlock_failure: %{reason: ":timeout", at: ~U[2026-08-12 18:55:00Z]}
    }

    assert Health.secrets_unlock_report(vm) == %{
             reason: ":timeout",
             at: "2026-08-12T18:55:00Z"
           }
  end

  test "corroborated_overall/roll_up are unaffected — this is informational only" do
    # A VM report with a recorded unlock failure must still be able to reach
    # :ok overall when every probe passes; secrets_unlock_failed is a sibling
    # key, not a check.
    vm = %Mjolnir.VM{
      id: "vm-1",
      net_config: %{guest_ip: "10.200.0.9"},
      secrets_unlock_failure: %{reason: ":timeout", at: DateTime.utc_now()}
    }

    assert Health.corroborated_overall(:ok, vm, []) == :ok
    assert Health.secrets_unlock_report(vm) != nil
  end
end
