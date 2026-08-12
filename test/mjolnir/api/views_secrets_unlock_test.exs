defmodule Mjolnir.API.ViewsSecretsUnlockTest do
  @moduledoc """
  mjolnir-3v2: `GET /api/vms/:id` must show a failed managed-secrets unlock so
  an operator doesn't have to grep logs to discover a VM is running without
  its secrets. Exercises `Mjolnir.API.Views.render_vm/1` directly against a
  hand-built VM struct (no hypervisor, no vsock).
  """
  use ExUnit.Case, async: true

  alias Mjolnir.API.Views

  test "a healthy (or non-managed) VM renders secrets_unlock_failed: nil" do
    vm = %Mjolnir.VM{id: "vm-1", secrets_unlock_failure: nil}
    assert Views.render_vm(vm).secrets_unlock_failed == nil
  end

  test "a failed unlock is rendered with reason and timestamp" do
    vm = %Mjolnir.VM{
      id: "vm-1",
      secrets_unlock_failure: %{reason: ":timeout", at: ~U[2026-08-12 18:55:00Z]}
    }

    assert Views.render_vm(vm).secrets_unlock_failed == %{
             reason: ":timeout",
             at: "2026-08-12T18:55:00Z"
           }
  end
end
