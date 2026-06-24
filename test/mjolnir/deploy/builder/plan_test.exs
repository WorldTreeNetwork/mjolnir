defmodule Mjolnir.Deploy.Builder.PlanTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Builder.Plan
  alias Mjolnir.Deploy.CacheKey

  @base "@base/ubuntu-24.04"

  # The three canonical build steps for a SvelteKit/adapter-node deploy.
  defp steps do
    [
      %{command: "mise install", input_hash: "runtime-node20"},
      %{command: "npm ci", input_hash: "lockfile-hash-aaa"},
      %{command: "npm run build", input_hash: "srctree-hash-bbb"}
    ]
  end

  # Recompute the chained layer ids the same way the planner does, so tests can
  # build an `existing` set without reaching into the planner's internals.
  defp chain_keys(base, steps) do
    {keys, _last} =
      Enum.map_reduce(steps, base, fn s, parent ->
        k = CacheKey.compute(parent, s.command, s.input_hash)
        {k, k}
      end)

    keys
  end

  describe "compute/3 — empty inputs" do
    test "no steps degenerates to release == base, nothing to run" do
      plan = Plan.compute(@base, [], [])

      assert plan.layers == []
      assert plan.steps_to_run == []
      assert plan.resume_from == @base
      assert plan.release_layer_id == @base
      assert plan.cache_hits == 0
      assert plan.cache_misses == 0
    end
  end

  describe "compute/3 — cold cache (nothing exists)" do
    test "every step is a miss; resume from base; release is the last layer" do
      [_k1, _k2, k3] = chain_keys(@base, steps())
      plan = Plan.compute(@base, steps(), [])

      assert plan.cache_hits == 0
      assert plan.cache_misses == 3
      assert plan.resume_from == @base
      assert plan.release_layer_id == k3
      assert length(plan.steps_to_run) == 3
      assert Enum.map(plan.layers, & &1.status) == [:miss, :miss, :miss]
    end
  end

  describe "compute/3 — warm cache" do
    test "all layers exist → all hits, nothing to run, resume from the last layer" do
      keys = chain_keys(@base, steps())
      plan = Plan.compute(@base, steps(), keys)

      assert plan.cache_hits == 3
      assert plan.cache_misses == 0
      assert plan.steps_to_run == []
      assert plan.resume_from == List.last(keys)
      assert plan.release_layer_id == List.last(keys)
      assert Enum.map(plan.layers, & &1.status) == [:hit, :hit, :hit]
    end

    test "only the first layer exists → resume after it, rebuild the tail" do
      [k1, _k2, k3] = chain_keys(@base, steps())
      plan = Plan.compute(@base, steps(), [k1])

      assert plan.cache_hits == 1
      assert plan.cache_misses == 2
      assert plan.resume_from == k1
      assert plan.release_layer_id == k3
      assert Enum.map(plan.steps_to_run, & &1.command) == ["npm ci", "npm run build"]
    end
  end

  describe "compute/3 — contiguous-prefix invariant" do
    test "a downstream key in the cache does NOT count as a hit once an ancestor missed" do
      [k1, _k2, k3] = chain_keys(@base, steps())

      # Cache contains the first and LAST layer ids but not the middle one.
      # The naive implementation (plain set membership) would mark layer 3 a hit;
      # the correct one must not, because layer 2 missed and breaks the chain.
      plan = Plan.compute(@base, steps(), [k1, k3])

      assert plan.cache_hits == 1
      assert plan.cache_misses == 2
      assert Enum.map(plan.layers, & &1.status) == [:hit, :miss, :miss]
      assert plan.resume_from == k1
      # k3 must still be rebuilt despite being present in the cache set.
      assert Enum.any?(plan.steps_to_run, &(&1.cache_key == k3))
    end
  end

  describe "compute/3 — chaining and parentage" do
    test "each layer's parent_id is the previous layer's cache_key (base for the first)" do
      plan = Plan.compute(@base, steps(), [])
      [l1, l2, l3] = plan.layers

      assert l1.parent_id == @base
      assert l2.parent_id == l1.cache_key
      assert l3.parent_id == l2.cache_key
    end

    test "changing one step's input_hash changes that layer and every layer after it" do
      base_plan = Plan.compute(@base, steps(), [])

      mutated =
        steps()
        |> List.update_at(1, fn s -> %{s | input_hash: "lockfile-hash-CHANGED"} end)

      mutated_plan = Plan.compute(@base, mutated, [])

      [b1, b2, b3] = base_plan.layers
      [m1, m2, m3] = mutated_plan.layers

      # Layer 1 (before the change) is identical...
      assert b1.cache_key == m1.cache_key
      # ...layer 2 (the changed step) and layer 3 (downstream) both differ.
      assert b2.cache_key != m2.cache_key
      assert b3.cache_key != m3.cache_key
    end
  end

  describe "compute/3 — determinism" do
    test "identical inputs produce an identical plan" do
      keys = chain_keys(@base, steps())
      existing = [hd(keys)]

      assert Plan.compute(@base, steps(), existing) == Plan.compute(@base, steps(), existing)
    end

    test "accepts a MapSet for existing_layer_ids" do
      [k1 | _] = chain_keys(@base, steps())
      plan = Plan.compute(@base, steps(), MapSet.new([k1]))

      assert plan.cache_hits == 1
    end
  end
end
