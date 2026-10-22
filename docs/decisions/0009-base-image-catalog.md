# ADR 0009 — Base image catalog

**Status:** Accepted (Fable accept 2026-09-10, `reviews/2026-09-10-readvise2.md`)
**Date:** 2026-08-27
**Change:** [`add-base-images`](../../openspec/changes/archive/2026-09-10-add-base-images/proposal.md) (folded 2026-09-10)
**Living spec:** [`openspec/specs/base-images/spec.md`](../../openspec/specs/base-images/spec.md)
**Epic:** `mjolnir-b0gb`

Full argument:
[`openspec/changes/archive/2026-09-10-add-base-images/design.md`](../../openspec/changes/archive/2026-09-10-add-base-images/design.md).

## One screen

1. **No toolchain-as-base.** `@base/` is OS roots. Node/bun/python
   are `mise` layers or golden snapshots, not extra debootstraps.
   `deploy-node-bun` is retired. Do not grow a replacement.
2. **Catalog v1 (closed list):** `ubuntu-24.04` (spawn **and**
   deploy default), `ci-ubuntu-24.04` (Forgejo runner; `@base/dev`
   later), `buzz-agent` (bodies), `arch` (optional, not default).
   Undeclared subvolumes are unmanaged, never auto-deleted. A pin
   produced by a declared alias's recipe is declared (archived),
   not unmanaged; unmanaged is a name with no recipe in this repo.
3. **Image must boot without inject.** Binary + unit + wants
   symlink are recipe post-conditions (`guest-agent.sh`). Inject
   is a refresh when `:guest_agent_bin` exists, not a crutch.
4. **Independent bootstrap recipes, shared helpers.** No FROM-ubuntu
   flavor DSL in this change. Share `scripts/lib/{guest-agent,mise,terminfo}.sh`.
   Arch is pacstrap; ubuntu-family is debootstrap.
5. **Rebuild declared live images from current recipes (v0).** A
   subvolume older than its recipe is not the catalog. Snapshot
   the previous image into `@snapshots/<name>-pre-rebuild-<date>`
   before replace. After an in-place alias rebuild, delete every
   `@snapshots/deploy-*` layer via `mj snapshot rm` /
   `DELETE /api/snapshots/:name` (sidecar included; not raw
   `btrfs subvolume delete`). Layers do not record a parent, so
   the chain is not separable. D6 removes this step. In-place on
   the alias name is OK while we own every app. Do not rebuild
   `deploy-node-bun` (D1) or unmanaged names. Human 2026-08-27.
6. **Pins are immutable; aliases move (v1).** `ubuntu-24.04` /
   `ubuntu-latest` are channels. `ubuntu-24.04-20260827` is a pin
   the recipe produces and never overwrites. Spawn/deploy resolve
   alias → pin and **record the pin** (VM, release, deploy cache
   parent). Redeploy keeps the pin unless the app opts into the
   alias. `node-latest` is this alias pattern, not a Node OS-root
   (D1). Implement as `mjolnir-b0gb.6` before a second tenant.
   Human 2026-08-27.

## Built vs remaining

Built (living spec, fold-now): catalog definition (unmanaged;
pin produced by a declared alias's recipe is declared archived);
`mj spawn` default `ubuntu-24.04`; toolchains are not OS roots
(review reject; `deploy-node-bun` is not a catalog name); declared
recipes bake guest agent so a clone boots without inject; v0
in-place rebuild of declared live images plus drop every
`@snapshots/deploy-*` layer; retired image is not rebuilt; flavors
are independent bootstrap recipes sharing helpers. D5 operator
rebuild on 45.76.77.97 (2026-08-27).

Remaining (do not import as living SHALLs): `remove-deploy-node-bun`
(`mjolnir-b0gb.2`) — Orchestrator default `ubuntu-24.04`, Node
deploy uses ubuntu+mise, recipes SHALL NOT produce
`deploy-node-bun`; `add-base-image-list` (`mjolnir-b0gb.3` /
`mjolnir-8vo`) — listing surfaces; `add-base-image-health`
(`mjolnir-b0gb.4` / `mjolnir-pj6t` / `mjolnir-hjnz`); then
`add-base-image-pins` (`mjolnir-b0gb.6`) — D6 pin/alias resolver.
