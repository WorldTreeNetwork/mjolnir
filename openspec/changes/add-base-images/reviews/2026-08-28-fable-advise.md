# add-base-images — architecture advise (cross-family reader)

> **ADVISE:** accept-with-nits

**Reader:** Fable 5 (Anthropic; cross-family per ADR-005), 2026-08-28.
**Author:** Grok 4.6. **Prior review:** human accept-with-nits D1–D4
plus D5/D6 (`reviews/2026-08-27-human-advise.md`).
**Scope:** advise for the *code* landings — `remove-deploy-node-bun`
(`mjolnir-b0gb.2`), `add-base-image-list` (`.3`),
`add-base-image-health` (`.4`). Read: proposal, design, tasks,
`specs/base-images/spec.md`, ADR 0009, human advise, and the cited
orchestrator / VM / builder / health / recipe code.

## Verdict

The architecture is sound and unusually well grounded: every load-bearing
claim in the design checked out against live code. `mj deploy` does
hard-default `deploy-node-bun` (`lib/mjolnir/deploy/orchestrator.ex:50`,
used at `orchestrator.ex:113`) while `mj spawn` already defaults
`ubuntu-24.04` (`config/config.exs:21`) — the drift is real and the flip
converges two defaults rather than inventing one. D3 is not aspiration:
`scripts/lib/guest-agent.sh:60-155` already implements exactly the
binary + unit + `basic.target.wants` post-condition with
`verify_guest_agent` failing the build and `ALLOW_NO_AGENT=1` as the
opt-out; the spec requirement is a description of shipped code. The
inject-is-a-silent-no-op claim is verifiable at `lib/mjolnir/vm.ex:2093-2102`
(the `if agent_bin && File.exists?` has no else branch — no log, no
warning). D6's "hashing the alias is cache poison" is also literal:
`Builder.build/3` defaults `base_image` to `base_layer_id`
(`lib/mjolnir/deploy/builder.ex:85-87,102`) and the orchestrator passes
the base-image *name* as that id (`orchestrator.ex:122`), so today two
different filesystems under one name would share a cache parent.

Nits are below; none is send-back grade. Two are directed at the
implementing nodes (findings 1 and 2), one is a spec-internal tension
to resolve at fold or in `mjolnir-b0gb.6` (finding 3).

## Steelman against

The strongest case against D1: retiring the baked image trades a
*reliability* property, not just ~30 seconds. `deploy-node-bun` made
first deploys self-contained; after retire, the first deploy of every
runtime spec per host does `mise install` over the network from inside
the build VM. A registry outage, a NAT regression (exactly the class
`Mjolnir.Health.Host` exists to catch), or an upstream yank now fails
a deploy that yesterday succeeded offline. And the cache that
amortizes this is keyed on the runtime spec (`orchestrator.ex:274`
classifies `mise*` as `:runtime`), so every runtime bump re-pays the
network cost at deploy time rather than at image-build time, where a
failure would be an operator's problem instead of a deploying user's.

The design's answer holds anyway: the baked image already produced
the worse failure — `:boot_timeout` with a bare `spawn_failed`
(mjolnir-bhcr), caused by rot nobody was watching — and freezing
bun@2026-08-07 into a debootstrap just moves the network fetch to a
build that happens so rarely nobody remembers how. A deploy-time
failure is at least attributed, retryable, and named in the progress
stream. The steelman argues for good *failure reporting* in the mise
layer, not for keeping the image.

## One real tradeoff

D4 fixes image rot but institutionalizes **recipe drift**. Four
independent debootstraps (`build-rootfs-ubuntu-24.04.sh`,
`build-ci-image.sh`, `build-buzz-agent-image.sh`, `build-rootfs-arch.sh`)
share only three helpers (`scripts/lib/{guest-agent,mise,terminfo}.sh`).
Everything outside the helpers — debootstrap flags, apt lists, systemd
tweaks, the networking hook — is copy-paste, and copy-paste across four
scripts is precisely the mechanism by which `ci-ubuntu-24.04` became
hand-patched and unreproducible last time (mjolnir-0e8: "four scripts
each grew their own copy of this, two of them incomplete",
`guest-agent.sh:23-26`). The design buys this knowingly ("copy-paste
across the remaining scripts is the known cost", design.md D4) and the
alternative it rejects — flavors as provision-from-ubuntu — genuinely
fails the rebuild-invalidation argument, since these are OS roots with
no layer cache. The tradeoff is correctly priced *if* drift stays
visible: the discipline that keeps it priced is "next shared failure →
next helper in `scripts/lib/`", and nothing in the spec enforces that.
Accepted, with eyes open.

## Findings

1. **Deleting `@base/deploy-node-bun` breaks L5 nuke for VMs whose
   spawn_config records it** (for `remove-deploy-node-bun`,
   `mjolnir-b0gb.2`). `Health.nuke/1` captures `base_image` from the
   StateStore spawn_config (`lib/mjolnir/health.ex:440-455`) and
   respawns via `VM.spawn_with_id` → `BTRFS.clone(base_image, vm_id)`
   (`lib/mjolnir/vm.ex:2140-2141`). A long-lived VM spawned from
   `deploy-node-bun` before the flip will, after subvolume deletion,
   fail the respawn and roll back (`health.ex:238-243` — recover-safe,
   no data loss, but L5 is permanently unavailable for that VM).
   Ordinary restart/Reconcile is unaffected (`vm.ex:2113-2126` resumes
   from the existing `@vms/<uuid>` rootfs). The retire node should
   sweep StateStore for `"base_image": "deploy-node-bun"` before
   deleting the subvolume, and either migrate those records to
   `ubuntu-24.04` or document that nuke of those VMs fails loudly.

2. **D5's in-place rebuild has a spawn-outage window the spec does not
   name.** The recipe deletes then recreates the live `@base/` name
   (design.md Risks: "destructive of the `@base/` name under v0"), so
   for the minutes of a debootstrap (longer for CI: rust + zig via
   mise) every default `mj spawn` and post-flip `mj deploy` fails with
   whatever error `BTRFS.clone` produces for a missing subvolume. The
   pre-rebuild snapshot is a rollback for a *failed* build, not a fix
   for the window. v0 mitigation is cheap: build into
   `@base/<name>.next` and swap, or just say "rebuild during a quiet
   window" in the runbook. D6 (build pin, retarget alias) eliminates
   the window structurally — one more reason `mjolnir-b0gb.6` should
   not slip past a second tenant. Low urgency: tonight's rebuilds are
   done (tasks.md:14-19); this bites the *next* v0 rebuild.

3. **D2 and D6 disagree about what a pin is.** D2 defines declared as
   "has a recipe in this repository **and** is in this table"
   (design.md Decision 2), and the spec makes everything else
   unmanaged (spec.md "An `@base/` subvolume that is not declared
   SHALL be unmanaged"). D6 puts pins in `@base/` "so they stay
   catalog entries" (spec.md "Pins SHALL live under `@base/`, not only
   `@snapshots/`"). A pin (`ubuntu-24.04-20260827`) is not in the
   catalog v1 table, so by the letter of D2 it is unmanaged — meaning
   post-b0gb.6, `mj bases` reports every archived pin alongside
   `tatastu-agent` as the same kind of stray. tasks.md:48-50 already
   reserves `kind`/`resolves_to` in the list schema, which is the
   right instinct; the definitional fix belongs in the fold or the
   b0gb.6 delta: a pin produced by a declared alias's recipe is
   *declared-archived*, not unmanaged. One sentence, but without it
   the "unmanaged, never auto-deleted" invariant and future pin GC
   ("GC of unreferenced pins is later", design.md D6) contradict each
   other — GC would be auto-deleting "unmanaged" names.

4. **Minor sequencing inconsistency in tasks.md.** The "After accept:
   pointer in `docs/architecture.md`" box is checked (tasks.md:22-23,
   commit `23c6f73`) while the advise-accept box above it is still
   open (tasks.md:20-21). Harmless — the human accept of D1–D4
   plausibly gates the pointer — but the checklist as written says the
   pointer landed before its stated precondition. Not a blocker;
   worth knowing the "after accept" in that line means the human
   accept, not this one.

## What is solid

- **D3 is shipped code described as a requirement**, the strongest kind
  of spec. `install_guest_agent` + `verify_guest_agent`
  (`guest-agent.sh:60-155`) already enforce binary + unit + wants
  symlink with a non-zero exit and the documented `ALLOW_NO_AGENT=1`
  escape. The spec scenarios ("Recipe omits the unit → exits non-zero")
  are tests of existing behaviour.
- **Catalog v1 maps 1:1 to recipes that exist.** All four declared
  names have build scripts in `scripts/`; the two excluded names are
  exactly the ones without a defensible recipe (`tatastu-agent`: none
  in repo; `deploy-node-bun`: `build-deploy-base.sh`, scheduled for
  deletion).
- **The unmanaged-never-auto-deleted rule** is the right conservative
  default for a namespace humans have been hand-dropping subvolumes
  into, and it is stated in both design and spec delta.
- **D6's cache-parent argument is verified, not speculative** —
  `builder.ex:102` plus `orchestrator.ex:122` show the alias string is
  the cache parent today. Recording the pin as `base_layer_id` is the
  correct minimal fix and CacheKey already has the `parent_layer_id`
  slot for it (`lib/mjolnir/deploy/cache_key.ex:70-75`).
- **The fold gate is stated correctly** (tasks.md:25-28): do not
  import the unimplemented deploy-default scenario into living specs
  before the retire act lands. This is the 2026-08-16 learning applied
  in advance rather than after.
- **Review hygiene**: the 2026-08-27 file records a *human* accept of
  same-family authorship and explicitly leaves the cross-family read
  open. This file closes it. No Grok self-accept occurred.

## Implementer gaps

For `remove-deploy-node-bun` (`mjolnir-b0gb.2`):
- Flip `@default_base_image` (`orchestrator.ex:50`) and fix the
  moduledoc, which also names the image (`orchestrator.ex:18`) — the
  moduledoc's "does not mount that share automatically" claim should be
  re-verified against `ubuntu-24.04` before landing.
- StateStore sweep for recorded `base_image: "deploy-node-bun"` before
  subvolume deletion (finding 1).
- Grep the tree: Justfile, docs, and `scripts/build-deploy-base.sh`
  all reference the name; the change deletes the script, the rest
  should not dangle.
- Land the `mjolnir.toml` / `--base` override here as scoped, so the
  flip ships with its escape hatch.

For `add-base-image-list` (`mjolnir-b0gb.3`):
- The declared list must live somewhere code can read it (module
  attribute, config, or a generated table from the ADR) — the ADR
  table alone is not queryable. Keep `kind`/`resolves_to` fields
  nullable now (tasks.md:48-50) so pins don't force a schema break.
- Resolve finding 3's declared/unmanaged/pin taxonomy before the JSON
  shape freezes it.

For `add-base-image-health` (`mjolnir-b0gb.4`):
- `Mjolnir.Health.Host.check/0` (`lib/mjolnir/health/host.ex:19-30`)
  is the natural seam; a base-image check is refuse-to-fix (names the
  recipe, does not rewrite `@base/`) per D3.
- Define "rotten" operationally: the check can verify D3's three
  artifacts in each declared subvolume cheaply; agent *staleness*
  (June-23-binary class) needs a comparator — binary hash vs a known
  current agent, or mtime vs recipe mtime. Pick one and state it,
  or the check degenerates to existence-only and misses exactly the
  mjolnir-hjnz case that motivated it.
- The noisy-inject half is one `else` branch with a `Logger.warning`
  at `vm.ex:2096-2102`; cheap, do it first.
