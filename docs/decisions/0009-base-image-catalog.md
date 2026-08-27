# ADR 0009 — Base image catalog

**Status:** Proposed
**Date:** 2026-08-27
**Change:** [`add-base-images`](../../openspec/changes/add-base-images/proposal.md)
**Living spec (after fold):** [`openspec/specs/base-images/spec.md`](../../openspec/specs/base-images/spec.md)
**Epic:** `mjolnir-b0gb`

Full argument:
[`openspec/changes/add-base-images/design.md`](../../openspec/changes/add-base-images/design.md).

## One screen

1. **No toolchain-as-base.** `@base/` is OS roots. Node/bun/python
   are `mise` layers or golden snapshots, not extra debootstraps.
   `deploy-node-bun` is retired. Do not grow a replacement.
2. **Catalog v1 (closed list):** `ubuntu-24.04` (spawn **and**
   deploy default), `ci-ubuntu-24.04` (Forgejo runner; `@base/dev`
   later), `buzz-agent` (bodies), `arch` (optional, not default).
   Undeclared subvolumes are unmanaged, never auto-deleted.
3. **Image must boot without inject.** Binary + unit + wants
   symlink are recipe post-conditions (`guest-agent.sh`). Inject
   is a refresh when `:guest_agent_bin` exists, not a crutch.
4. **Independent debootstraps, shared helpers.** No FROM-ubuntu
   flavor DSL in this change. Share `scripts/lib/{guest-agent,mise,terminfo}.sh`.
5. **Rebuild declared live images from current recipes (v0).** A
   subvolume older than its recipe is not the catalog. Snapshot
   the previous image into `@snapshots/<name>-pre-rebuild-<date>`
   before replace. In-place on the alias name is OK while we own
   every app. Do not rebuild `deploy-node-bun` (D1) or unmanaged
   names. Human 2026-08-27.
6. **Pins are immutable; aliases move (v1).** `ubuntu-24.04` /
   `ubuntu-latest` are channels. `ubuntu-24.04-20260827` is a pin
   the recipe produces and never overwrites. Spawn/deploy resolve
   alias → pin and **record the pin** (VM, release, deploy cache
   parent). Redeploy keeps the pin unless the app opts into the
   alias. `node-latest` is this alias pattern, not a Node OS-root
   (D1). Implement as `mjolnir-b0gb.6` before a second tenant.
   Human 2026-08-27.

## Built vs remaining

Built: D5 operator rebuild on 45.76.77.97 (2026-08-27). Nothing of
the catalog API, Orchestrator default flip, or pin/alias resolver.

Remaining: `remove-deploy-node-bun` (`mjolnir-b0gb.2`),
`add-base-image-list` (`mjolnir-b0gb.3` / `mjolnir-8vo`),
`add-base-image-health` (`mjolnir-b0gb.4` / `mjolnir-pj6t` /
`mjolnir-hjnz`), then `add-base-image-pins` (`mjolnir-b0gb.6`).
