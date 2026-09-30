# add-deploy-step-inputs

> **PENDING**

First of four build-caching changes: `add-deploy-step-inputs` →
`add-deploy-build-sizing` → `add-deploy-build-caches` →
`add-deploy-artifacts`. This one needs no new storage.

## Why

`Orchestrator.plan_to_steps/3` keys every declared step that is not a
`mise …` or a known install command on the hash of the whole source tree,
and layer keys chain through their parent. One edited file therefore
invalidates every layer of a manifest app, including
`apt-get install …`, which reads no source at all. identikey's 2026-09-29
deploys logged `0 hit / 4 miss` for a source-only change and rebuilt apt,
the web bundle and all 446 Rust crates each time. The only living mention
of these layers is `base-images` ("`deploy-*` content-addressed layers"),
so nothing states what a layer is keyed on.

## What

- New capability `deploy-build`. It first states today's layer contract:
  content-addressed `deploy-<key>` btrfs snapshots, one per step, chained
  through the parent key, and a full hit boots no VM.
- A declared step may be a table `{ run, inputs }`. `inputs` is a list of
  globs relative to the source root (the equivalent of GitHub's
  `hashFiles`). The step is keyed on the hash of the matching files and
  receives only those files in `/app`.
- `inputs = []` keys the step on its command alone, with no source copy.
- A plain string step keeps today's behavior: whole-tree key, full copy.
  No manifest already in use changes meaning.
- `mj deploy` progress names each layer as hit or miss, and the reason
  (command, inputs, parent).

## Impact

- Capabilities: ADDED `deploy-build`
- Modules: `Deploy.Manifest` (step tables), `Deploy.Orchestrator`
  (`plan_to_steps`, preludes), `Deploy.CacheKey` (glob hashing)
- ADRs: none

## User journey & surfaces

The operator edits `mjolnir.toml` and runs `mj deploy`, the surface they
use today.

- Working: `[build] 2 hit / 2 miss`, then one line per layer, e.g.
  `apt: hit (command only)` and `cargo: miss (inputs changed)`.
- Empty: a manifest with no table steps shows today's output plus
  per-layer reasons.
- Failed: a table step with an unknown key, or `inputs` that is not a list
  of strings, fails `mj deploy` before any VM boots and names the step.
- Off: no switch; string steps are the old behavior.

## Out of scope

- Mutable build caches (`target/`, package stores) are
  `add-deploy-build-caches`.
- Build VM size is `add-deploy-build-sizing`.
- Inferring `inputs` for string steps: explicit only. A later change may
  infer from detector knowledge; not tracked yet.
