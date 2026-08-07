defmodule Mjolnir.Deploy.RuntimeRegistryIntegrationTest do
  # gge.12.1 acceptance, exercised against the REAL Mjolnir.Deploy.Registry.
  #
  # runtime_test.exs already covers custom_domain preservation, but it stubs
  # registry_get/registry_put with plain closures — so it proves Runtime *passes*
  # custom_domain along, not that the Registry *keeps* it. The reported failure
  # lives in the seam between them: `Registry.build_entry/2` constructs a FRESH
  # %Entry{} via Map.get(attrs, :custom_domain), and write_atomic overwrites the
  # JSON wholesale, so any key Runtime omits is silently erased on disk. Then
  # RouteReconciler.desired_specs filters on is_binary(custom_domain) and drops
  # the app's gateway route entirely.
  #
  # These tests run a real redeploy sequence (two Runtime.start calls with
  # different snapshots and VM ids) against a real Registry backed by a tmp dir,
  # and assert the domain is still there — in ETS and in the JSON on disk.
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Registry
  alias Mjolnir.Deploy.Runtime

  @plan %{start_command: "node build/index.js", port: 3000}

  setup do
    dir = Path.join(System.tmp_dir!(), "deploy-reg-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, pid} = Registry.start_link(dir: dir, name: nil)
    %{registry: pid, dir: dir}
  end

  # VM-side ops are stubbed (no hypervisor in unit tests); the registry ops are
  # the real thing.
  defp ops(registry, vm_id) do
    %{
      spawn: fn _boot -> {:ok, %{id: vm_id}} end,
      get_ticket: fn _vm -> {:ok, "zticket-#{vm_id}"} end,
      exec: fn _vm, _cmd, _o -> {:ok, ""} end,
      stop: fn _vm -> :ok end,
      registry_get: fn app -> Registry.get(registry, app) end,
      registry_put: fn app, attrs -> Registry.put(registry, app, attrs) end
    }
  end

  defp deploy(registry, app, snapshot, vm_id, opts \\ []) do
    Runtime.start(
      app,
      snapshot,
      @plan,
      [ops: ops(registry, vm_id), gateway_domain: "vm.example.test"] ++ opts
    )
  end

  defp on_disk(dir, app) do
    dir |> Path.join("#{app}.json") |> File.read!() |> Jason.decode!()
  end

  test "custom_domain survives a redeploy in ETS and on disk", ctx do
    app = "canary"

    {:ok, _} = deploy(ctx.registry, app, "rel-1", "vm-1", custom_domain: "canary.example.test")
    {:ok, first} = Registry.get(ctx.registry, app)
    assert first.custom_domain == "canary.example.test"
    assert first.service_vm_id == "vm-1"

    # The redeploy: new snapshot, new service VM, and NO custom_domain opt —
    # which is exactly how a plain `mj deploy` re-runs an existing app.
    {:ok, _} = deploy(ctx.registry, app, "rel-2", "vm-2")

    {:ok, second} = Registry.get(ctx.registry, app)

    assert second.service_vm_id == "vm-2", "the redeploy should cut over to the new VM"
    assert second.release_snapshot == "rel-2"

    assert second.custom_domain == "canary.example.test",
           "redeploy wiped custom_domain — RouteReconciler.desired_specs filters on " <>
             "is_binary(custom_domain), so the app's gateway route would be dropped (gge.12.1)"

    # The JSON is the source of truth the reconciler and a restart both read.
    assert on_disk(ctx.dir, app)["custom_domain"] == "canary.example.test"
  end

  test "custom_domain survives several consecutive redeploys", ctx do
    app = "canary-multi"
    {:ok, _} = deploy(ctx.registry, app, "rel-1", "vm-1", custom_domain: "multi.example.test")

    for n <- 2..5 do
      {:ok, _} = deploy(ctx.registry, app, "rel-#{n}", "vm-#{n}")
    end

    {:ok, entry} = Registry.get(ctx.registry, app)
    assert entry.service_vm_id == "vm-5"
    assert entry.custom_domain == "multi.example.test"
    assert on_disk(ctx.dir, app)["custom_domain"] == "multi.example.test"
  end

  test "an explicit custom_domain on a redeploy retargets the app", ctx do
    app = "canary-retarget"
    {:ok, _} = deploy(ctx.registry, app, "rel-1", "vm-1", custom_domain: "old.example.test")
    {:ok, _} = deploy(ctx.registry, app, "rel-2", "vm-2", custom_domain: "new.example.test")

    {:ok, entry} = Registry.get(ctx.registry, app)
    assert entry.custom_domain == "new.example.test"
    assert on_disk(ctx.dir, app)["custom_domain"] == "new.example.test"
  end

  test "an app deployed with no domain stays without one", ctx do
    app = "canary-nodomain"
    {:ok, _} = deploy(ctx.registry, app, "rel-1", "vm-1")
    {:ok, _} = deploy(ctx.registry, app, "rel-2", "vm-2")

    {:ok, entry} = Registry.get(ctx.registry, app)
    assert entry.custom_domain == nil
    assert entry.service_vm_id == "vm-2"
  end

  test "a fresh Registry reloads the preserved domain from disk", ctx do
    app = "canary-reload"
    {:ok, _} = deploy(ctx.registry, app, "rel-1", "vm-1", custom_domain: "reload.example.test")
    {:ok, _} = deploy(ctx.registry, app, "rel-2", "vm-2")

    # Models an orchestrator restart: a new Registry loading the same directory.
    # This is the path that took startupcentral.build down on 2026-08-07 — a
    # restart re-reading state that a redeploy had quietly emptied.
    {:ok, reloaded} = Registry.start_link(dir: ctx.dir, name: nil)
    {:ok, entry} = Registry.get(reloaded, app)

    assert entry.custom_domain == "reload.example.test"
    assert entry.service_vm_id == "vm-2"
  end
end
