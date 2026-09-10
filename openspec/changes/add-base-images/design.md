# Design — base image catalog

Canonical ADR index:
[`docs/decisions/0009-base-image-catalog.md`](../../../docs/decisions/0009-base-image-catalog.md).
This file is the full argument.

**Status:** Proposed. ACTIVE BUILD. Human accepted D1–D4 2026-08-27
and added D5 (rebuild declared live images).
**Change:** `add-base-images`
**Epic:** `mjolnir-b0gb`
**Bead:** `mjolnir-b0gb.1`

Grok authored. Human accepted D1–D4 in chat 2026-08-27 (cross-check
for those four). Fable 5 is still the cross-family reader for the
code landings. Sol is not subscribed.

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
| `arch` | Optional spawn (`mj spawn --base arch`, `just deploy-rootfs distro=arch`) | Not a default. Recipe sources `guest-agent.sh` (D3). |

A name is declared when it has a recipe in this repo **and** is in
this table. Adding a name is an ADR amend, not a new script dropped
on the server. A pin produced by a declared alias's recipe is
declared (archived), not unmanaged. Unmanaged is a name with no
recipe in this repo (`tatastu-agent` today; `deploy-node-bun`
until deleted). Later `mj bases` lists unmanaged names as such.
They are never auto-deleted. Discovering them is the operator
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
post-condition. All four declared recipes source that helper
(arch included, 2026-09-10). A recipe that produces an image
missing any of these fails the build (`ALLOW_NO_AGENT=1` is the
explicit opt-out).

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

## Decision 5 — Rebuild declared live images from current recipes

Human 2026-08-27: the Jun 23 `ubuntu-24.04` (and the other declared
images that predate the post-0e8 / post-xx5 recipes) are not the
catalog. A declared name on a host SHALL be produced by the current
recipe, with a current guest agent baked in.

Operator sequence:

1. Snapshot `@base/<name>` → `@snapshots/<name>-pre-rebuild-<date>`
   (rollback; never auto-delete).
2. Build or reuse a current `mjolnir-agent` at `AGENT_BIN`.
3. Run the recipe (`just deploy-rootfs`, `just build-ci-image`,
   `just build-buzz-agent-image`).
4. Spawn from the new image; vsock ping must succeed without
   inject. Then tear the probe VM down.
5. Delete `@snapshots/deploy-*` layers whose cache parent is the
   rebuilt alias. `CacheKey.compute` hashes `parent_layer_id` as a
   string (`cache_key.ex:74-75`); `Builder` defaults that to the
   base-image name (`builder.ex:102`); the orchestrator passes the
   alias (`orchestrator.ex:122`). A changed filesystem under the
   same name is otherwise a silent cache hit. Latent until retire
   flips the deploy default; live from then until `mjolnir-b0gb.6`.

Order on 45.76.77.97: `ubuntu-24.04` first (spawn + deploy default),
then `ci-ubuntu-24.04`, `buzz-agent`, `arch`. Do **not** rebuild
`deploy-node-bun` (D1) or `tatastu-agent` (unmanaged).

Running VMs keep their `@vms/<uuid>` clones. Replacing `@base/`
does not bounce them. New spawns get the new image.

Rejected:

- **Leave ubuntu as Jun 23 and rely on inject.** The prod inject
  path has already been missing (`mjolnir-hjnz`). D3 forbids it.
- **Rebuild `deploy-node-bun` as part of “old ones.”** D1.

## Decision 6 — Pins are immutable; aliases move

Human 2026-08-27: in-place rebuild of `@base/ubuntu-24.04` is
acceptable **v0** while we are the only tenant. It is the wrong
contract once other people's apps live here for years. A redeploy
that cache-misses the first layer (or that is a first deploy of a
new app) currently clones whatever that *name* is today. The name
moved; the app did not ask it to.

Two names, Docker-shaped:

| Kind | Example | Mutates? |
|---|---|---|
| **Alias** (channel) | `ubuntu-24.04`, `ubuntu-latest` | Yes — retargeted at rebuild |
| **Pin** (identity) | `ubuntu-24.04-20260827` | No — recipe output, archived |

`node-latest` in the request is this **alias pattern**, not a Node
OS-root. D1 still holds: language runtimes are mise layers. The
same pin/alias split applies there: Detector's `node@20` is a
channel; `node@20.20.2` is a pin. Do not grow `@base/node-latest`.

**Rebuild** produces a new pin, then retargets the alias. It does
not delete the previous pin. v0 D5 snapshots to
`@snapshots/<name>-pre-rebuild-<date>` are a rollback hatch in the
wrong namespace (`mj spawn --snapshot`, not `--base`). v1 pins live
in `@base/` so they stay catalog entries.

**Spawn / deploy** resolve an alias to a pin at the moment of
clone. The **pin** is what gets recorded:

- on the VM / release (so `mj info` names the identity, not only
  the channel)
- as `base_layer_id` in deploy cache keys (`CacheKey` parent).
  Hashing the alias string is cache poison: two different
  filesystems would share a key.

**Redeploy** of an existing app uses the recorded pin. Following
the alias is explicit (`mj deploy --pull-base` or a manifest
`base_image = "ubuntu-24.04"` with a pull flag — bikeshed at
implement). A first deploy of a new app may follow the alias.

**GC** of unreferenced pins is later. A pin that any app, release
snapshot, deploy layer, or running VM still names is not garbage.
Unmanaged names stay unmanaged (D2).

v0 (now): keep D5's in-place rebuild; we own every app. v1 is
`add-base-image-pins` (`mjolnir-b0gb.6`), after list/health, before
we take a second tenant. Do not redo tonight's rebuilds as pins.

Rejected:

- **Pins only as `@snapshots/`.** Repeats mjolnir-97c (`--base` vs
  `--snapshot`). Archive is still a catalog OS root.
- **Content-address `@base/b3/<hash>` in v1.** Right shape for a
  registry; overkill while pins are dated recipe outputs on one
  host. Revisit when bases move across hosts.
- **Always follow the alias on redeploy.** That is the bug D6
  exists to stop.
- **Never have aliases.** Then every app pins a date and nobody
  gets the new agent without editing a manifest.

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
- Recipe rebuild of ubuntu is destructive of the `@base/` name
  under v0 (the script deletes then recreates). Pre-rebuild
  snapshots in `@snapshots/` are the rollback. D6 is the durable
  fix (new pin, retarget alias). A failed debootstrap must restore
  from the snapshot before new spawns are attempted.
- `@base/dev` vs leftover `ci-ubuntu-24.04` drift remains (Buzz
  design). Catalog v1 keeps the CI name so the runner labels keep
  working.

## Review

Authoring pass: Grok 4.6 (this file). Human accepted D1–D4
2026-08-27 and added D5 (rebuild) then D6 (pins + aliases). A
second-family read is still owed before `act` on retire / list /
health. D6 is plan-only until `mjolnir-b0gb.6`.
