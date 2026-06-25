defmodule Mjolnir.Deploy.BuilderTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Builder
  alias Mjolnir.Deploy.CacheKey

  @base "@base/ubuntu-24.04"

  defp steps do
    [
      %{command: "mise install", input_hash: "runtime-node20"},
      %{command: "npm ci", input_hash: "lockfile-hash-aaa"},
      %{command: "npm run build", input_hash: "srctree-hash-bbb"}
    ]
  end

  # Recompute the chained layer ids the same way the planner does, so a test can
  # seed an `existing` snapshot set without reaching into Builder/Plan internals.
  defp chain_keys(base, steps) do
    {keys, _last} =
      Enum.map_reduce(steps, base, fn s, parent ->
        k = CacheKey.compute(parent, s.command, s.input_hash)
        {k, k}
      end)

    keys
  end

  # A recording ops seam. Every effect appends a tagged event to an Agent so the
  # test can assert on the exact call sequence. `existing` is the list of deploy
  # layer ids (without prefix) that the fake BTRFS cache already holds.
  defp recording_ops(agent, opts) do
    existing = Keyword.get(opts, :existing, [])
    prefix = Keyword.get(opts, :prefix, "deploy-")
    fail_on = Keyword.get(opts, :exec_fail_on)
    spawn_result = Keyword.get(opts, :spawn_result, {:ok, %{id: "build-vm-1"}})

    snapshots = Enum.map(existing, fn id -> %{name: prefix <> id} end)

    %{
      list_snapshots: fn ->
        Agent.update(agent, &[{:list_snapshots} | &1])
        {:ok, snapshots}
      end,
      spawn: fn boot ->
        Agent.update(agent, &[{:spawn, boot} | &1])
        spawn_result
      end,
      exec: fn vm_id, command, _o ->
        Agent.update(agent, &[{:exec, vm_id, command} | &1])
        if command == fail_on, do: {:error, {:exit_code, 1, "boom"}}, else: {:ok, "ok"}
      end,
      snapshot: fn vm_id, name, _o ->
        Agent.update(agent, &[{:snapshot, vm_id, name} | &1])
        {:ok, %{name: name}}
      end,
      stop: fn vm_id ->
        Agent.update(agent, &[{:stop, vm_id} | &1])
        :ok
      end
    }
  end

  defp events(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> [] end})
    %{agent: agent}
  end

  describe "build/3 — full cache hit" do
    test "boots no VM when every layer already exists", %{agent: agent} do
      keys = chain_keys(@base, steps())
      ops = recording_ops(agent, existing: keys)

      assert {:ok, result} = Builder.build(@base, steps(), ops: ops)

      assert result.cache_hits == 3
      assert result.cache_misses == 0
      assert result.built == []
      assert result.release_layer_id == List.last(keys)
      assert result.release_snapshot == "deploy-" <> List.last(keys)

      # Only the cache was consulted — nothing was booted, run, or snapshotted.
      tags = events(agent) |> Enum.map(&elem(&1, 0))
      assert tags == [:list_snapshots]
    end
  end

  describe "build/3 — cold build (empty cache)" do
    test "boots from the base image and builds every layer in order", %{agent: agent} do
      keys = chain_keys(@base, steps())
      ops = recording_ops(agent, existing: [])

      assert {:ok, result} = Builder.build(@base, steps(), ops: ops, base_image: "ubuntu-24.04")

      assert result.cache_hits == 0
      assert result.cache_misses == 3
      assert result.built == keys
      assert result.release_snapshot == "deploy-" <> List.last(keys)

      ev = events(agent)

      # list → spawn(base image) → (exec; snapshot) ×3 → stop
      assert [
               {:list_snapshots},
               {:spawn, %{base_image: "ubuntu-24.04"}},
               {:exec, "build-vm-1", "mise install"},
               {:snapshot, "build-vm-1", s1},
               {:exec, "build-vm-1", "npm ci"},
               {:snapshot, "build-vm-1", s2},
               {:exec, "build-vm-1", "npm run build"},
               {:snapshot, "build-vm-1", s3},
               {:stop, "build-vm-1"}
             ] = ev

      assert [s1, s2, s3] == Enum.map(keys, &("deploy-" <> &1))
    end
  end

  describe "build/3 — partial cache hit" do
    test "resumes from the deepest cached layer and only runs the tail", %{agent: agent} do
      keys = chain_keys(@base, steps())
      [l1, l2, _l3] = keys
      # L1 and L2 are cached; only the final build step should rerun.
      ops = recording_ops(agent, existing: [l1, l2])

      assert {:ok, result} = Builder.build(@base, steps(), ops: ops)

      assert result.cache_hits == 2
      assert result.cache_misses == 1
      assert result.built == [List.last(keys)]

      ev = events(agent)

      assert [
               {:list_snapshots},
               {:spawn, %{snapshot: resume}},
               {:exec, "build-vm-1", "npm run build"},
               {:snapshot, "build-vm-1", _s3},
               {:stop, "build-vm-1"}
             ] = ev

      # Resumed from L2's snapshot (the deepest contiguous hit).
      assert resume == "deploy-" <> l2
    end
  end

  describe "build/3 — failure handling" do
    test "aborts on a failed step but still tears the VM down", %{agent: agent} do
      ops = recording_ops(agent, existing: [], exec_fail_on: "npm ci")

      assert {:error, {:step_failed, "npm ci", {:exit_code, 1, "boom"}, built}} =
               Builder.build(@base, steps(), ops: ops)

      # The first layer built before the failure is reported.
      [l1 | _] = chain_keys(@base, steps())
      assert built == [l1]

      ev = events(agent)

      # First step snapshotted, second step's exec failed, so it was never
      # snapshotted: exactly one snapshot happened before the abort.
      assert {:snapshot, "build-vm-1", _} = Enum.at(ev, 3)
      assert {:exec, "build-vm-1", "npm ci"} = Enum.at(ev, 4)
      assert Enum.count(ev, &match?({:snapshot, _, _}, &1)) == 1
      # Teardown always runs — the last event is the stop.
      assert List.last(ev) == {:stop, "build-vm-1"}
    end

    test "surfaces a spawn failure without running any steps", %{agent: agent} do
      ops = recording_ops(agent, existing: [], spawn_result: {:error, :no_kvm})

      assert {:error, {:spawn_failed, :no_kvm}} = Builder.build(@base, steps(), ops: ops)

      tags = events(agent) |> Enum.map(&elem(&1, 0))
      assert tags == [:list_snapshots, :spawn]
    end
  end

  describe "build/3 — no steps" do
    test "degenerates to release == base image, no VM booted", %{agent: agent} do
      ops = recording_ops(agent, existing: [])

      assert {:ok, result} = Builder.build(@base, [], ops: ops, base_image: "ubuntu-24.04")

      assert result.cache_misses == 0
      assert result.built == []
      assert result.release_layer_id == @base
      assert result.release_snapshot == "ubuntu-24.04"

      tags = events(agent) |> Enum.map(&elem(&1, 0))
      assert tags == [:list_snapshots]
    end
  end
end
