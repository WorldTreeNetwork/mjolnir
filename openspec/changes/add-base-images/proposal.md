# add-base-images

> **ACTIVE BUILD**

Activated from intend 2026-08-27 (`nod-base-catalog`).
Epic `mjolnir-b0gb`. Bead `mjolnir-b0gb.1`.

**Rigor:** architecture

## Why

`@base/` is a pile of one-off debootstraps that rot. `mj deploy`
hard-defaults to `deploy-node-bun` (`lib/mjolnir/deploy/orchestrator.ex`),
a Node/bun specialisation built 2026-08-07, while `mj spawn` already
defaults to `ubuntu-24.04`. The deploy guide already maps `FROM node:…`
to a clone of `@base/ubuntu-24.04` plus a cached `mise` layer. The
specialised image is the drift: it was hand-patched, it is not a
catalog entry, and the next “we need python” request will grow another
script just like it. `tatastu-agent` already did, with no recipe in
this repo.

## What

- Add capability `base-images`: `@base/` is a **declared catalog of
  OS roots**. `@snapshots/` is frozen machines (including `deploy-*`
  layers). Toolchains are not OS roots.
- Accept ADR 0009 (`docs/decisions/0009-base-image-catalog.md`, full
  text in `design.md`). Six decisions, D1–D6. Human accepted D1–D4
  2026-08-27, added D5 (rebuild declared live images) and D6 (pins
  immutable, aliases move; v1 before a second tenant).
- This change is the architecture write (ADR + deltas). Code is
  `act` of later nodes after advise accept (`remove-deploy-node-bun`,
  `add-base-image-list`, `add-base-image-health`). Rebuild of
  declared images is an operator landing on this change (`mjolnir-b0gb.5`).

## Impact

- Capabilities: ADDED `base-images` (materialized by fold)
- ADRs: 0009 (this change). Pointer from `docs/architecture.md` after
  accept.
- Does not rebuild or keep `deploy-node-bun`.
- Does rebuild declared catalog images from current recipes (D5, v0
  in-place).
- Does not implement pin/alias resolution (D6, `mjolnir-b0gb.6`).
- Does not add a FROM-ubuntu flavor DSL.

## User journey & surfaces

Who: operator deploying an app or spawning a shell.
Surfaces: `mj deploy`, `mj spawn --base`, `mj doctor` (host), and
today `ssh` + `btrfs subvolume list` to discover `@base/`.

- **Working (after later act)** — `mj deploy` builds from
  `ubuntu-24.04`; first `mise install` is a cached layer; `mj bases`
  lists the catalog; `mj doctor` names a rotten image instead of
  “Host ok” followed by `:boot_timeout`.
- **Empty** — `openspec/specs/base-images/` does not exist yet.
  Correct: fold creates it.
- **Failed (today)** — `mj deploy` defaults to `deploy-node-bun`.
  Live `ubuntu-24.04` is a Jun 23 debootstrap (agent too old for
  managed unlock). Declared images that predate the current recipe
  are not the catalog.
- **Off** — Duke parks. ADR is amended in place, not deleted.

## Out of scope

- Orchestrator default flip + script/subvolume deletion —
  `remove-deploy-node-bun` (`mjolnir-b0gb.2`); supersedes
  `mjolnir-gge.1.10` and `mjolnir-bhcr`
- `GET /api/base-images` / `mj bases` — `add-base-image-list`
  (`mjolnir-b0gb.3` / `mjolnir-8vo`)
- `mj doctor` + noisy `inject_guest_agent` — `add-base-image-health`
  (`mjolnir-b0gb.4` / `mjolnir-pj6t` / `mjolnir-hjnz`)
- `mjolnir.toml` / `mj deploy --base` override — useful half of
  `mjolnir-6ee1`; lands with the retire node
- Converging `ci-ubuntu-24.04` → `@base/dev` — Buzz design Decision 6,
  later
- Cross-host image distribution
- Unifying the remaining debootstrap scripts into one recipe DSL
- Auto-deleting unmanaged `@base/` entries (`tatastu-agent`)
- Pin/alias resolver, recording the pin on deploy, alias pull flag —
  `add-base-image-pins` (`mjolnir-b0gb.6`). v0 in-place rebuild
  stands until then.
