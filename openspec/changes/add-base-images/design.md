# Design — base image catalog

Canonical ADR index:
[`docs/decisions/0009-base-image-catalog.md`](../../../docs/decisions/0009-base-image-catalog.md).
This file is the full argument.

**Status:** Proposed. ACTIVE BUILD.
**Change:** `add-base-images`
**Epic:** `mjolnir-b0gb`
**Bead:** `mjolnir-b0gb.1`

Grok authored. Advise reader must not be Grok (ADR-005). Fable 5 is
the cross-family reader. Sol is not subscribed.

## Problem

Four questions after intend:

1. Is a specialised toolchain image (`deploy-node-bun`) an OS root,
   or a layer on one?
2. Which `@base/` names are the catalog, and what happens to names
   with no recipe (`tatastu-agent`)?
3. Does a clone boot if `:guest_agent_bin` is missing? (It must.)
4. Are CI / Buzz / ubuntu one debootstrap with flavors, or separate
   recipes sharing helpers?

Live on 45.76.77.97 (2026-08-27): `ubuntu-24.04` (Jun 23),
`deploy-node-bun` (Aug 7, agent hand-copied today), `ci-ubuntu-24.04`
(Aug 12), `buzz-agent` (Aug 7), `arch` (Apr 20), `tatastu-agent`
(Aug 25, no recipe in this repo). Five build scripts under
`scripts/build-*.sh`. Helpers already factored:
`scripts/lib/{guest-agent,mise,terminfo}.sh`.

The deploy guide already states the intended mapping
(`docs/guide/deploying-an-app.md`): `FROM node:…` is a clone of
`@base/ubuntu-24.04` plus `mise` as a cached layer. The code
drifted: `Mjolnir.Deploy.Orchestrator` defaults
`base_image` to `"deploy-node-bun"`. `mj spawn` already defaults to
`ubuntu-24.04` (`config/config.exs`). The ubuntu recipe already
installs `mise`. Detector already emits `"mise install"` as step 1,
keyed on the runtime spec (`plan_to_steps` classifies `mise*` as
`:runtime`).

## Decision 1 — No toolchain-as-base

A base image is an **OS root**: kernel-compatible userspace, guest
agent, networking hook, `mise` as the tool that grows other tools.
It is not `node:20`. It is not `python:3.12`.

`@base/deploy-node-bun` is retired. Do not rebuild it. Do not grow
`deploy-python`, `deploy-rust`, or a sibling. A Node (or Python, or
Rust) runtime is:

- **Deploy:** the cached `mise install` layer, keyed on the runtime
  spec. First pay on a host; then a snapshot hit.
- **Humans:** `mj spawn` from `ubuntu-24.04`, install what you want,
  `mj snapshot` a golden name into `@snapshots/`.

The ~30s that motivated `gge.1.10` is real and is paid **once per
runtime spec per host**, then cached as a `deploy-*` snapshot. That
is the Mjolnir-shaped cost. Baking bun@latest into a debootstrap
freezes a date (2026-08-07 → bun 1.3.14, node 20.20.2) and then
rots.

Rejected:

- **Rebuild `deploy-node-bun` in place.** Fixes today's boot, keeps
  the class of bug (`mjolnir-bhcr`, `mjolnir-0e8`).
- **Bake node@20 + bun into `ubuntu-24.04`.** Makes the default
  spawn image a Node image. The next runtime request fattens it
  again.
- **Use `ci-ubuntu-24.04` as the deploy default.** CI is a runner
  user + extra mounts + a fat toolchain. Deployed apps should not
  inherit that.

`mjolnir.toml` / `mj deploy --base` remain an override (the useful
half of `mjolnir-6ee1`) so a non-Node app, or a future declared
flavor, can pin a catalog name without an rpc.

## Decision 2 — Catalog v1 is a closed list

Declared `@base/` names:

| Name | Who | Notes |
|---|---|---|
| `ubuntu-24.04` | `mj spawn` default **and** `mj deploy` default | Recipe: `scripts/build-rootfs-ubuntu-24.04.sh`. Has `mise`. |
| `ci-ubuntu-24.04` | Forgejo runner (`ubuntu-24.04:mjolnir:ci-ubuntu-24.04`) | Recipe: `scripts/build-ci-image.sh`. Converge to `@base/dev` later (Buzz design Decision 6). Not this change. |
| `buzz-agent` | Buzz remote-agent bodies | Recipe: `scripts/build-buzz-agent-image.sh`. |
| `arch` | Optional spawn (`mj spawn --base arch`, `just deploy-rootfs distro=arch`) | Not a default. Kept while the recipe exists. |

A name is declared when it has a recipe in this repo **and** is in
this table. Adding a name is an ADR amend, not a new script dropped
on the server.

Undeclared subvolumes (`tatastu-agent` today; `deploy-node-bun`
until deleted) are **unmanaged**. Later `mj bases` lists them as
such. They are never auto-deleted. Discovering them is the operator
surface (`add-base-image-list`); garbage-collecting them is a human.

`@base/` vs `@snapshots/` vs deploy layers:

```
@base/<declared>          OS root. Recipe. Rebuilt infrequently.
@snapshots/<name>         Frozen machine. Human or deploy named it.
@snapshots/deploy-<key>   Content-addressed build layer. Cache.
@vms/<uuid>               Running clone. Disposable.
```

A snapshot is spawnable (`mj spawn --snapshot`). It is not a catalog
entry. Mixing the two namespaces is `mjolnir-97c` (closed: `--base`
vs `--snapshot`). Listing `@base/` is still missing (`mjolnir-8vo`).

## Decision 3 — Image must boot without inject

A catalog image SHALL contain:

1. `/usr/local/bin/mjolnir-agent`
2. `/etc/systemd/system/mjolnir-agent.service`
3. `basic.target.wants` symlink

`scripts/lib/guest-agent.sh` `install_guest_agent` is the
post-condition. A recipe that produces an image missing any of
these fails the build (`ALLOW_NO_AGENT=1` is the explicit opt-out).

`Mjolnir.VM.inject_guest_agent/1` is a **refresh** of the binary in
a clone when `:guest_agent_bin` exists. It is not how a new image
gains an agent. On 45.76.77.97 the configured path does not exist,
so inject is a silent no-op (`mjolnir-hjnz`). That is why
`deploy-node-bun` booted to `:boot_timeout` (`mjolnir-bhcr`) and why
`ubuntu-24.04`'s June 23 agent is what actually runs.

Doctor and the inject warning are `add-base-image-health`. This
decision is the contract they check.

Rejected:

- **Rely on inject.** The prod path is already missing. 0e8 closed
  the builder hole; live images were not rebuilt.
- **Auto-heal by rewriting `@base/`.** Doctor refuses-to-fix and
  names the rebuild recipe.

## Decision 4 — Independent debootstraps, shared helpers, no flavor DSL

`ubuntu-24.04`, `ci-ubuntu-24.04`, and `buzz-agent` stay **separate
debootstrap recipes**. They are not `FROM ubuntu-24.04` snapshots.

CI has a `runner` user, virtio-fs workspace mounts, and a fat
mise-managed toolchain (rust, zig). Buzz has sprig as the
signal-receiving process (I5) and optional goose/npm agents. Those
are different userspaces, not `apt install` on the default root.

Helpers already exist and stay the only shared surface:

- `scripts/lib/guest-agent.sh`
- `scripts/lib/mise.sh`
- `scripts/lib/terminfo.sh`

Do not invent a FROM-ubuntu flavor DSL, a Packer HCL, or a second
builder binary in this change. Copy-paste across the remaining
scripts is the known cost; a DSL is a new product. Unifying recipes
is a later refactor, not a catalog requirement.

Rejected:

- **One ubuntu debootstrap, everything else a snapshot-from-ubuntu
  provision.** Attractive on paper. CI and Buzz diverge enough
  (users, PID 1, extra mounts) that the provision script becomes
  the debootstrap anyway, plus a parent-image rebuild now invalidates
  every flavor with no layer cache to save you — these are OS roots,
  not deploy steps.
- **Keep `build-deploy-base.sh` as the Node flavor.** Decision 1.

## Alternatives rejected (whole)

- **Rebuild `deploy-node-bun` and keep it as the deploy default.**
  Intend: get rid of it. The guide already names ubuntu + mise.
- **Empty `@base/` except ubuntu.** Drops CI and Buzz bodies.
- **Treat `@snapshots/` as the catalog.** Snapshots are user/app
  artifacts. The catalog is what a host is *supposed* to have.

## Risks

- First Node `mj deploy` after retire pays `mise install` (network,
  ~30s). Subsequent deploys of the same runtime spec hit cache.
  Existing `deploy-*` layers keyed on `deploy-node-bun` as parent
  miss. Accepted.
- `ubuntu-24.04` live image is Jun 23 (agent too old for managed
  unlock — `mjolnir-hjnz`). Retire does not rebuild it. Injection
  still needs a real `:guest_agent_bin` on the host. Health node
  names that. A `just deploy-rootfs` of ubuntu is a separate
  operator act, not this ADR.
- `@base/dev` vs leftover `ci-ubuntu-24.04` drift remains (Buzz
  design). Catalog v1 keeps the CI name so the runner labels keep
  working.

## Review

Authoring pass: Grok 4.6 (this file). Same family as the intend
reader. A second-family or human read is owed before `act` on
retire / list / health. Do not treat this file as self-approved.
