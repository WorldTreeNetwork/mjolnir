defmodule Mjolnir.Deploy.Builder.Plan do
  @moduledoc """
  Pure cache-decision planner for the deploy snapshot-layer builder.

  Given a base layer, an ordered list of build steps (each carrying a
  precomputed `input_hash`), and the set of layer ids that already exist in the
  snapshot cache, `compute/3` decides — without booting anything — which layers
  are cache hits, where the build should resume, and which steps still need to
  run.

  ## The chained-key invariant

  Each layer's id is `Mjolnir.Deploy.CacheKey.compute(parent_layer_id, command,
  input_hash)`, where the parent of layer N is the id of layer N-1 (the base
  layer for the first step). Because every key folds in its parent, changing any
  step changes that layer's id *and every id downstream of it*. Consequently the
  set of cache hits is always a **contiguous prefix**: the moment one step
  misses, no later step can legitimately hit. The planner enforces this
  structurally (it stops counting hits at the first miss) rather than relying on
  the astronomically-unlikely absence of a coincidental key collision.

  This module is the macOS-verifiable core of `Mjolnir.Deploy.Builder`. The
  VM/BTRFS execution half — boot `resume_from`, run each `steps_to_run` command
  via `Mjolnir.VM.exec`, snapshot the result to its `cache_key` — is server-
  gated and lives elsewhere (still-open task under mjolnir-gge.1.4).

  ## Caller contract

  The planner is pure data-in/data-out: the caller precomputes each step's
  `input_hash` (install steps → `CacheKey.hash_file/1` of the lockfile; build
  steps → `CacheKey.hash_tree/2` of the source) so that no filesystem access
  leaks into the planner. This also fixes the data shape the server-side
  executor consumes.
  """

  alias Mjolnir.Deploy.CacheKey

  @typedoc "A build step with its command and a precomputed input hash."
  @type step_input :: %{required(:command) => String.t(), required(:input_hash) => String.t()}

  @type status :: :hit | :miss

  @typedoc "A planned layer: its id, the parent it was keyed against, and cache status."
  @type layer :: %{
          command: String.t(),
          cache_key: String.t(),
          parent_id: String.t(),
          status: status()
        }

  @typedoc "A layer that must actually be built (a cache miss), in run order."
  @type run_step :: %{
          command: String.t(),
          cache_key: String.t(),
          parent_id: String.t()
        }

  use TypedStruct

  typedstruct enforce: true do
    @typedoc """
    The resolved build plan.

    - `base_layer_id` — the snapshot the chain starts from.
    - `layers` — every step resolved to a layer id + hit/miss status, in order.
    - `resume_from` — the layer to boot the build VM from: the deepest contiguous
      cache hit, or `base_layer_id` if the very first step misses.
    - `steps_to_run` — the cache-miss layers, in order; what the executor builds.
    - `release_layer_id` — the final layer id (the deployable release), or
      `base_layer_id` when there are no steps.
    - `cache_hits` / `cache_misses` — counts, for logging/telemetry.
    """
    field(:base_layer_id, String.t())
    field(:layers, [Mjolnir.Deploy.Builder.Plan.layer()])
    field(:resume_from, String.t())
    field(:steps_to_run, [Mjolnir.Deploy.Builder.Plan.run_step()])
    field(:release_layer_id, String.t())
    field(:cache_hits, non_neg_integer())
    field(:cache_misses, non_neg_integer())
  end

  @doc """
  Resolves the layer chain and cache decisions for a build.

  `existing_layer_ids` is any enumerable of layer ids known to exist in the
  cache (a list or `MapSet`). Returns a `%Plan{}`; never raises for an empty
  step list (degenerates to "nothing to build, release == base").
  """
  @spec compute(String.t(), [step_input()], Enumerable.t()) :: t()
  def compute(base_layer_id, steps, existing_layer_ids)
      when is_binary(base_layer_id) and is_list(steps) do
    existing = MapSet.new(existing_layer_ids)

    {layers_rev, _parent, _still_hitting} =
      Enum.reduce(steps, {[], base_layer_id, true}, fn step, {acc, parent_id, still_hitting} ->
        command = Map.fetch!(step, :command)
        input_hash = Map.fetch!(step, :input_hash)
        cache_key = CacheKey.compute(parent_id, command, input_hash)

        # A layer is a hit only if every layer before it hit AND its key exists.
        # The `still_hitting` guard makes the hit set a structural prefix.
        hit? = still_hitting and MapSet.member?(existing, cache_key)
        status = if hit?, do: :hit, else: :miss

        layer = %{command: command, cache_key: cache_key, parent_id: parent_id, status: status}
        {[layer | acc], cache_key, hit?}
      end)

    layers = Enum.reverse(layers_rev)
    {hits, misses} = Enum.split_with(layers, &(&1.status == :hit))

    resume_from =
      case List.last(hits) do
        nil -> base_layer_id
        layer -> layer.cache_key
      end

    steps_to_run =
      Enum.map(misses, fn l ->
        %{command: l.command, cache_key: l.cache_key, parent_id: l.parent_id}
      end)

    release_layer_id =
      case List.last(layers) do
        nil -> base_layer_id
        layer -> layer.cache_key
      end

    %__MODULE__{
      base_layer_id: base_layer_id,
      layers: layers,
      resume_from: resume_from,
      steps_to_run: steps_to_run,
      release_layer_id: release_layer_id,
      cache_hits: length(hits),
      cache_misses: length(misses)
    }
  end
end
