defmodule Mjolnir.Deploy.Builder do
  @moduledoc """
  Snapshot-layer build executor — the VM/BTRFS half of the deploy builder.

  Given a base layer and an ordered list of build steps, `build/3`:

    1. Lists the deploy layer snapshots that already exist in the BTRFS cache.
    2. Asks the pure `Mjolnir.Deploy.Builder.Plan` planner which layers hit, where
       to resume, and which steps still need to run.
    3. On a **full cache hit** (nothing to run) returns immediately — no VM is
       booted; the release snapshot already exists.
    4. Otherwise boots a single **ephemeral build VM** from `resume_from` (the
       base image when resuming from the base, else the deepest cached layer
       snapshot), runs each remaining step over vsock with `VM.exec`, and
       snapshots the result after each step to that layer's content-addressed
       name. The ephemeral VM is **always torn down** when the build finishes,
       fails, or aborts — build-then-promote, never reused as a service VM.

  Because `VM.snapshot` quiesces-then-resumes the guest, the entire layer chain
  is built on one VM: exec a step, snapshot it to its cache key, then exec the
  next step on the still-live VM. There is no per-layer reboot.

  ## The ops seam (why this module is unit-testable on macOS)

  All VM and BTRFS effects go through an injectable `ops` map. The default
  `ops` are thin captures of `Mjolnir.VM` / `Mjolnir.BTRFS`, which only run on a
  real Mjolnir server (KVM + BTRFS). Tests pass fake `ops` that record the call
  sequence, so the boot → exec → snapshot → teardown *choreography* — including
  the cache-hit short-circuit and guaranteed teardown on failure — is verified
  without any infrastructure. Only the captures themselves are server-gated.

  ## Layer id ↔ snapshot name

  The planner is deliberately snapshot-name-agnostic: it works in opaque layer
  ids (content-addressed cache keys). This module owns the one translation the
  planner avoids — a layer id `K` is stored as the BTRFS snapshot `"deploy-" <>
  K` (prefix configurable via the `:prefix` option). The base layer id is *not*
  a deploy layer: it names the spawnable base image directly.

  ## Caller contract

  `steps` is `[%{command: String.t(), input_hash: String.t()}]` with each
  `input_hash` precomputed by the caller (lockfile hash for install steps,
  source-tree hash for build steps — see `Mjolnir.Deploy.CacheKey`). This is the
  same shape the planner consumes; the Builder forwards it through unchanged.
  """

  require Logger

  alias Mjolnir.Deploy.Builder.Plan

  @default_prefix "deploy-"

  @typedoc """
  The injectable effect seam. Each entry is a function capture; the defaults
  target `Mjolnir.VM` / `Mjolnir.BTRFS`. Tests override with fakes.
  """
  @type ops :: %{
          list_snapshots: (-> {:ok, [map()]} | {:error, term()}),
          spawn: (map() -> {:ok, map()} | {:error, term()}),
          exec: (String.t(), String.t(), keyword() -> {:ok, String.t()} | {:error, term()}),
          snapshot: (String.t(), String.t(), keyword() -> {:ok, map()} | {:error, term()}),
          stop: (String.t() -> :ok | {:error, term()})
        }

  @typedoc "A successful build outcome."
  @type result :: %{
          release_layer_id: String.t(),
          release_snapshot: String.t(),
          plan: Plan.t(),
          built: [String.t()],
          cache_hits: non_neg_integer(),
          cache_misses: non_neg_integer()
        }

  @doc """
  Builds the layer chain for `base_layer_id` + `steps`, reusing cached layers.

  ## Options

    - `:ops` — effect seam overrides (map). Merged over the real-server defaults;
      tests pass fakes here. See `t:ops/0`.
    - `:prefix` — BTRFS snapshot-name prefix for deploy layers. Default
      `#{inspect(@default_prefix)}`.
    - `:base_image` — image name to spawn when resuming from the base layer.
      Defaults to `base_layer_id` (the base layer id *is* the base image name in
      the P0 flow).
    - `:spawn_opts` — extra spawn options merged into the boot map (e.g.
      `%{memory_mb: 2048, vcpus: 4}`).
    - `:exec_timeout` — per-step exec timeout passed to `VM.exec`. Default
      `:infinity` (builds can be long).

  Returns `{:ok, result}` (see `t:result/0`) or `{:error, reason}`. On any
  spawn/exec/snapshot failure the ephemeral VM is still torn down before the
  error is returned.
  """
  @spec build(String.t(), [Plan.step_input()], keyword()) :: {:ok, result()} | {:error, term()}
  def build(base_layer_id, steps, opts \\ [])
      when is_binary(base_layer_id) and is_list(steps) do
    ops = Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    base_image = Keyword.get(opts, :base_image, base_layer_id)
    spawn_opts = Keyword.get(opts, :spawn_opts, %{})
    exec_timeout = Keyword.get(opts, :exec_timeout, :infinity)

    with {:ok, existing} <- existing_layer_ids(ops, prefix) do
      plan = Plan.compute(base_layer_id, steps, existing)
      release_snapshot = release_snapshot_name(plan, base_layer_id, base_image, prefix)

      if plan.steps_to_run == [] do
        # Full cache hit: the release snapshot already exists. No VM is booted.
        Logger.info(
          "Deploy.Builder: full cache hit (#{plan.cache_hits} layers), release=#{release_snapshot}"
        )

        {:ok, finalize(plan, release_snapshot, [])}
      else
        run_build(ops, plan, base_layer_id, base_image, prefix, spawn_opts, exec_timeout,
          release_snapshot: release_snapshot
        )
      end
    end
  end

  # --- build execution -------------------------------------------------------

  defp run_build(ops, plan, base_layer_id, base_image, prefix, spawn_opts, exec_timeout, meta) do
    release_snapshot = Keyword.fetch!(meta, :release_snapshot)
    boot = boot_opts(plan, base_layer_id, base_image, prefix, spawn_opts)

    Logger.info(
      "Deploy.Builder: #{plan.cache_hits} hit / #{plan.cache_misses} miss; " <>
        "resume from #{inspect(boot)}, #{length(plan.steps_to_run)} step(s) to run"
    )

    case ops.spawn.(boot) do
      {:ok, vm} ->
        vm_id = Map.fetch!(vm, :id)

        try do
          case run_steps(ops, vm_id, plan.steps_to_run, prefix, exec_timeout) do
            {:ok, built} -> {:ok, finalize(plan, release_snapshot, built)}
            {:error, _} = err -> err
          end
        after
          # Build-then-promote: the ephemeral VM is never a service VM.
          discard_vm(ops, vm_id)
        end

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # Run each remaining step in order: exec the command, then snapshot the result
  # to the layer's content-addressed name. Aborts on the first failure, returning
  # the layers built so far so the caller can see partial progress.
  defp run_steps(ops, vm_id, steps_to_run, prefix, exec_timeout) do
    # `skip_verify` is applied ONLY to the final layer's snapshot. Intermediate
    # layers must keep the post-snapshot guest health-verify: run_steps snapshots
    # the SAME running VM and keeps exec-ing it for the next step, so a guest that
    # the snapshot's pause/resume left wedged (mjolnir-8ie) must surface loudly
    # *now* rather than as a baffling exec failure on the next step. The final
    # layer has no successor exec and the ephemeral VM is torn down immediately
    # after, so a post-snapshot guest hiccup there should not fail an otherwise
    # intact snapshot — the whole point of the cold/skip-verify mode.
    last_index = length(steps_to_run) - 1

    steps_to_run
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, built} ->
      snapshot_name = prefix <> step.cache_key
      snapshot_opts = if index == last_index, do: [skip_verify: true], else: []

      with {:ok, _out} <- ops.exec.(vm_id, step.command, timeout: exec_timeout),
           {:ok, _meta} <- ops.snapshot.(vm_id, snapshot_name, snapshot_opts) do
        {:cont, {:ok, [step.cache_key | built]}}
      else
        {:error, reason} ->
          Logger.error("Deploy.Builder: step #{inspect(step.command)} failed: #{inspect(reason)}")

          # Capture the guest's side of the story BEFORE run_build's `after`
          # clause discards the VM. The serial console is the only place the
          # guest KERNEL speaks, and without it an OOM-killed build and a
          # genuinely broken command are indistinguishable — both arrive as
          # {:vsock_unavailable, ...}. See Mjolnir.Deploy.Diagnostics.
          diag = capture_diagnostics(ops, vm_id, step.command, reason)

          {:halt, {:error, {:step_failed, step.command, reason, Enum.reverse(built), diag}}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      other -> other
    end
  end

  # Never lets a diagnostics problem mask the build failure that triggered it:
  # a missing serial log, a full disk, an unwritable state dir — all of those
  # must still leave the caller with the original {:step_failed, ...}.
  defp capture_diagnostics(ops, vm_id, command, reason) do
    case ops.diagnostics.(vm_id, command: command, reason: reason) do
      {:ok, capture} ->
        Logger.error("Deploy.Builder: #{Mjolnir.Deploy.Diagnostics.summarize(capture)}")
        %{diagnostics_dir: capture.dir, highlights: capture.highlights}

      {:error, _} ->
        %{diagnostics_dir: nil, highlights: []}
    end
  rescue
    e ->
      Logger.warning("Deploy.Builder: diagnostics capture raised: #{Exception.message(e)}")
      %{diagnostics_dir: nil, highlights: []}
  end

  defp discard_vm(ops, vm_id) do
    case ops.stop.(vm_id) do
      :ok ->
        :ok

      {:error, reason} ->
        # Teardown failure must not mask the build outcome; log and move on.
        Logger.warning("Deploy.Builder: failed to discard build VM #{vm_id}: #{inspect(reason)}")
        :ok
    end
  end

  # --- planning helpers ------------------------------------------------------

  # The boot map for the ephemeral build VM: spawn from the base image when the
  # plan resumes at the base, otherwise reflink-clone the deepest cached layer.
  defp boot_opts(plan, base_layer_id, base_image, prefix, spawn_opts) do
    base =
      if plan.resume_from == base_layer_id do
        %{base_image: base_image}
      else
        %{snapshot: prefix <> plan.resume_from}
      end

    Map.merge(base, Map.new(spawn_opts))
  end

  # The snapshot to spawn the eventual service VM from. When there are no steps
  # the release is the base image itself; otherwise it is the final layer.
  defp release_snapshot_name(plan, base_layer_id, base_image, prefix) do
    if plan.release_layer_id == base_layer_id do
      base_image
    else
      prefix <> plan.release_layer_id
    end
  end

  defp existing_layer_ids(ops, prefix) do
    case ops.list_snapshots.() do
      {:ok, snapshots} ->
        ids =
          snapshots
          |> Enum.map(&snapshot_name/1)
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&String.replace_prefix(&1, prefix, ""))

        {:ok, ids}

      {:error, reason} ->
        {:error, {:list_snapshots_failed, reason}}
    end
  end

  # Snapshot metadata maps come back with atom keys from BTRFS.list_snapshots/0;
  # tolerate string keys too so fakes/JSON round-trips don't need atomizing.
  defp snapshot_name(%{name: name}) when is_binary(name), do: name
  defp snapshot_name(%{"name" => name}) when is_binary(name), do: name

  defp finalize(plan, release_snapshot, built) do
    %{
      release_layer_id: plan.release_layer_id,
      release_snapshot: release_snapshot,
      plan: plan,
      built: built,
      cache_hits: plan.cache_hits,
      cache_misses: plan.cache_misses
    }
  end

  # --- default (server-gated) effect seam ------------------------------------

  defp default_ops do
    %{
      list_snapshots: &Mjolnir.BTRFS.list_snapshots/0,
      spawn: &Mjolnir.VM.spawn/1,
      exec: &Mjolnir.VM.exec/3,
      snapshot: &Mjolnir.VM.snapshot/3,
      stop: &Mjolnir.VM.stop/1,
      diagnostics: &Mjolnir.Deploy.Diagnostics.capture/2
    }
  end
end
