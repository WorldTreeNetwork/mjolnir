defmodule Mjolnir.Policy.CoverageTest do
  @moduledoc """
  Verifies that every router endpoint has policy enforcement.

  This test reads the router source and checks that all endpoints
  (except explicitly whitelisted ones) reference a policy module
  or use the authorize_vm helper.
  """
  use ExUnit.Case, async: true

  @router_path "lib/mjolnir/api/router.ex"
  @whitelisted_paths [
    "/api/health",
    "/api/health/host",
    "/api/health/host/heal",
    "/api/storage"
  ]

  # These patterns indicate policy enforcement is present.
  # Be specific to avoid false positives — generic patterns like "Enum.filter"
  # would match non-authz uses.
  @policy_patterns [
    "authorize_vm",
    # record-level ownership check for endpoints acting on stranded/:failed
    # records that have no live VM (retire/revive — mjolnir-5fu)
    "authorize_record",
    "Policy.VM.authorize",
    "Policy.Snapshot.authorize",
    # inline ownership filter (vm list, snapshot list, dormant list)
    ~S|user_id == "localhost" or|,
    # ownership stamped at resource creation (spawn)
    ":owner_id, conn.assigns",
    # deployed-app ownership (mjolnir-xuv): registry-entry owner checks for the
    # domain endpoints, POST /api/deploy (checked inside handle_deploy, once the
    # app name is known from the uploaded source), and the /api/apps list filter
    "authorize_app",
    "authorize_deploy",
    "Policy.App.filter_readable"
  ]

  test "all non-whitelisted endpoints have policy enforcement" do
    source = File.read!(@router_path)

    # Extract endpoint blocks: each starts with get/post/delete "/api/..."
    # and ends at the next endpoint or end of module
    endpoint_regex =
      ~r/(get|post|delete|put|patch)\s+"(\/api\/[^"]+)"\s+do\n(.*?)(?=\n\s+(?:get|post|delete|put|patch|forward|match)\s|end\nend)/s

    endpoints =
      Regex.scan(endpoint_regex, source)
      |> Enum.map(fn [_full, method, path, body] ->
        {String.upcase(method), path, body}
      end)

    assert length(endpoints) > 0, "Should find at least one endpoint in router"

    unprotected =
      endpoints
      |> Enum.reject(fn {_method, path, _body} ->
        path in @whitelisted_paths
      end)
      |> Enum.reject(fn {_method, _path, body} ->
        Enum.any?(@policy_patterns, fn pattern ->
          String.contains?(body, pattern)
        end)
      end)

    if unprotected != [] do
      paths = Enum.map(unprotected, fn {method, path, _} -> "#{method} #{path}" end)
      flunk("Endpoints without policy enforcement:\n  #{Enum.join(paths, "\n  ")}")
    end
  end

  test "whitelisted paths are explicitly documented" do
    # Ensure we're not silently skipping enforcement. Whitelist rationale:
    # - /api/health: liveness probe for load balancers; must be unauthenticated.
    # - /api/health/host: host-wide health report (KVM module, IP forwarding,
    #   btrfs mount, NAT rule, etc). Read-only and contains no per-VM secrets;
    #   gated by require_scope("vms:read") but not a VM-scoped Policy call.
    # - /api/health/host/heal: idempotent host-wide heal (sysctl, NAT, dirs).
    #   Affects all VMs collectively, not any one VM. Gated by
    #   require_scope("vms:exec"); no per-VM ownership check is meaningful.
    # - /api/storage: host-wide disk-usage aggregate (per-area totals, counts).
    #   Read-only, no per-VM secrets or owner-scoped data; gated by
    #   require_scope("vms:read"). Like /api/health/host, an ownership check is
    #   not meaningful for a fabric-wide total.
    assert @whitelisted_paths == [
             "/api/health",
             "/api/health/host",
             "/api/health/host/heal",
             "/api/storage"
           ],
           "Update this test when adding new whitelisted paths"
  end
end
