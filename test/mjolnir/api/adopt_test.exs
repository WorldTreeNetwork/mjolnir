defmodule Mjolnir.API.AdoptTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.Adopt
  alias Mjolnir.Deploy.Registry.Entry

  defp entry(attrs) do
    struct(
      Entry,
      Map.merge(
        %{
          app_name: "buzz-relay",
          release_snapshot: "old-snap",
          service_vm_id: "vm-1",
          port: 3000,
          stateful: true,
          updated_at: 1
        },
        attrs
      )
    )
  end

  defp fake_ops(agent) do
    %{
      registry_get: fn app ->
        case Agent.get(agent, &Map.get(&1, {:app, app})) do
          nil -> {:error, :not_found}
          e -> {:ok, e}
        end
      end,
      registry_put: fn app, attrs ->
        e =
          struct(
            Entry,
            Map.merge(%{app_name: app, updated_at: 2, stateful: true}, attrs)
          )

        Agent.update(agent, &Map.put(&1, {:app, app}, e))
        {:ok, e}
      end,
      vm_get: fn vm_id ->
        case Agent.get(agent, &Map.get(&1, {:vm, vm_id})) do
          nil -> {:error, :not_found}
          vm -> {:ok, vm}
        end
      end,
      snapshot: fn vm_id, name ->
        Agent.update(agent, &Map.put(&1, :snap, {vm_id, name}))
        {:ok, %{name: name}}
      end,
      reconcile: fn -> Agent.update(agent, &Map.put(&1, :reconciled, true)) end
    }
  end

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> %{{:vm, "vm-1"} => %{id: "vm-1"}} end})
    %{agent: agent, ops: fake_ops(agent)}
  end

  test "adopts a running VM and snapshots it", %{agent: agent, ops: ops} do
    assert {:ok, entry} =
             Adopt.adopt("buzz-relay", "vm-1", 3000, ops: ops, owner_id: "duke")

    assert entry.app_name == "buzz-relay"
    assert entry.service_vm_id == "vm-1"
    assert entry.port == 3000
    assert entry.stateful == true
    assert entry.owner_id == "duke"
    assert String.starts_with?(entry.release_snapshot, "adopt-buzz-relay-")
    assert Agent.get(agent, & &1.reconciled) == true
    assert { "vm-1", snap} = Agent.get(agent, & &1.snap)
    assert snap == entry.release_snapshot
  end

  test "uses a supplied release_snapshot and does not snapshot", %{agent: agent, ops: ops} do
    assert {:ok, entry} =
             Adopt.adopt("buzz-relay", "vm-1", 3000,
               ops: ops,
               release_snapshot: "already-there"
             )

    assert entry.release_snapshot == "already-there"
    assert Agent.get(agent, &Map.get(&1, :snap)) == nil
  end

  test "refuses a missing VM", %{ops: ops} do
    assert {:error, :vm_not_found} = Adopt.adopt("buzz-relay", "nope", 3000, ops: ops)
  end

  test "refuses to steal a non-stateful app", %{agent: agent, ops: ops} do
    Agent.update(agent, &Map.put(&1, {:app, "zine"}, entry(%{app_name: "zine", stateful: false})))

    assert {:error, :app_exists} = Adopt.adopt("zine", "vm-1", 3000, ops: ops)
  end

  test "refuses rebinding a stateful app to a different VM", %{agent: agent, ops: ops} do
    Agent.update(agent, &Map.put(&1, {:app, "buzz-relay"}, entry(%{})))
    Agent.update(agent, &Map.put(&1, {:vm, "vm-2"}, %{id: "vm-2"}))

    assert {:error, :stateful_vm_mismatch} =
             Adopt.adopt("buzz-relay", "vm-2", 3000, ops: ops)
  end

  test "idempotent adopt of the same VM", %{agent: agent, ops: ops} do
    Agent.update(agent, &Map.put(&1, {:app, "buzz-relay"}, entry(%{})))

    assert {:ok, entry} = Adopt.adopt("buzz-relay", "vm-1", 3000, ops: ops)
    assert entry.service_vm_id == "vm-1"
    assert entry.stateful == true
  end
end
