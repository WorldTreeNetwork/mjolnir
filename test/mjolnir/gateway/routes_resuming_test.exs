defmodule Mjolnir.Gateway.RoutesResumingTest do
  @moduledoc """
  mjolnir-ird: a deploy dropped a live customer route for the seconds between
  the boot-time render and the next one.

  A restart tears down and resumes every VM (Cleanup kills, Reconcile resumes).
  The route render runs while that is in flight, sees a VM that is not `:running`
  *this instant*, and treats it as a VM that should not have a route. Absence
  during boot was being read as intent.

  These tests drive `render_and_reload/1` WITHOUT passing `:running_vm_ids`, so
  they exercise the real default resolution — which is where the bug was. A test
  that passed the set in would have gone on passing throughout.

  NOT async: the StateStore is process-global.
  """
  use ExUnit.Case, async: false

  alias Mjolnir.Deploy.Registry.Entry
  alias Mjolnir.Gateway.Routes
  alias Mjolnir.StateStore
  alias Mjolnir.StateStore.Record

  @apexes ["identikey.io"]

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "routes-resuming-#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  defp entry(vm_id, fqdn) do
    struct!(%Entry{app_name: "zine", release_snapshot: "snap", updated_at: 0},
      app_name: "zine",
      service_vm_id: vm_id,
      custom_domain: fqdn,
      port: 3000
    )
  end

  defp render(path, entries) do
    Routes.render_and_reload(
      apexes: @apexes,
      registry_entries: entries,
      extra_domains: [],
      path: path,
      reload: fn -> :ok end,
      ip_resolver: fn _ -> "10.0.0.9" end
    )
  end

  test "a VM that is resuming — record on disk, no GenServer yet — keeps its route", ctx do
    # This is the exact deploy-time state. Reconcile has not rebuilt the
    # GenServer, so the VM is absent from VM.list/0 entirely; only the durable
    # :running record says it is meant to be up. Before the fix this rendered
    # zero routes and the domain 400'd until the next render.
    vm_id = "vm-resuming-#{System.unique_integer([:positive])}"
    :ok = StateStore.put(Record.new(vm_id, :running))
    on_exit(fn -> StateStore.delete(vm_id) end)

    assert {:ok, routes} = render(ctx.path, [entry(vm_id, "zine.identikey.io")])

    assert [%Routes.Route{apex: "identikey.io", subdomain: "zine"}] = routes
  end

  test "a VM that is genuinely gone gets no route", ctx do
    # The other half of the contract. Widening the set must not make removal
    # impossible, or a destroyed app keeps a route pointing at nothing.
    vm_id = "vm-absent-#{System.unique_integer([:positive])}"

    assert {:ok, []} = render(ctx.path, [entry(vm_id, "zine.identikey.io")])
  end

  test "a retired VM — record present but intent :failed — gets no route", ctx do
    # Reconcile retires a VM to :failed after repeated resume failures. That is
    # a VM that is gone, not one between states, so its route must drop.
    vm_id = "vm-failed-#{System.unique_integer([:positive])}"
    :ok = StateStore.put(Record.new(vm_id, :failed))
    on_exit(fn -> StateStore.delete(vm_id) end)

    assert {:ok, []} = render(ctx.path, [entry(vm_id, "zine.identikey.io")])
  end

  test "a stopped VM gets no route", ctx do
    vm_id = "vm-stopped-#{System.unique_integer([:positive])}"
    :ok = StateStore.put(Record.new(vm_id, :stopped))
    on_exit(fn -> StateStore.delete(vm_id) end)

    assert {:ok, []} = render(ctx.path, [entry(vm_id, "zine.identikey.io")])
  end

  test "a deploy-shaped render does not REMOVE a route for a resuming VM", ctx do
    # The acceptance criterion, stated the way the incident was observed: the
    # second render (mid-resume) must not drop what the first one wrote.
    vm_id = "vm-deploy-#{System.unique_integer([:positive])}"
    :ok = StateStore.put(Record.new(vm_id, :running))
    on_exit(fn -> StateStore.delete(vm_id) end)

    entries = [entry(vm_id, "zine.identikey.io")]

    assert {:ok, [_]} = render(ctx.path, entries)
    before = File.read!(ctx.path)

    # Render again with the VM still only a record — i.e. still resuming.
    assert {:ok, [_]} = render(ctx.path, entries)
    assert File.read!(ctx.path) == before
  end
end
