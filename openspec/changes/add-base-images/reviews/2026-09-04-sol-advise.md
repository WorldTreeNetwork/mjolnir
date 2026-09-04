# add-base-images — architecture advise (sol / other-family)

> **ADVISE:** accept
> **READER:** sol-arch-review
> **SPAWN:** /home/dorje/work/IdentiKey/mjolnir/.spawns/advise-add-base-images-sol-1788532385-417746-a3a0e3c5

**Author:** Grok 4.6. **Reader:** sol-arch-review (other-family, ADR-005).
Stand-in for the Fable 5.1 gate that could not run. A 2026-09-04
opus-4.8 accept already exists at `reviews/2026-09-04-advise.md`;
this file does not replace it. Verdict is on the architecture write
(ADR 0009 + deltas), not on unwritten retire/list/health/pins code.

**Prior reads:** human accept-with-nits D1–D4 + D5/D6
(`reviews/2026-08-27-human-advise.md`); Fable 5 accept-with-nits
(`reviews/2026-08-28-fable-advise.md`); opus-4.8 accept
(`reviews/2026-09-04-advise.md`).

## Blind pass (Why + living spec + cited code only, before
design.md / tasks.md)

Written independently, then compared. Concerns the author must have
answered — not a competing design.

1. **The default split is real and the flip must not ship a broken
   deploy.** `orchestrator.ex:50,113` hard-defaults `deploy-node-bun`;
   `config.exs:21` already defaults spawn to `ubuntu-24.04`. ADR 0009
   line 16 retires the specialised image. That only converges if
   `ubuntu-24.04` already grows Node via a keyed `mise` layer.
2. **Inject-as-refresh cannot be the boot path.** Spec D3: a clone
   of a declared image answers vsock when inject is a no-op. If the
   live `@base/` names predate that contract, D3 is paper.
3. **Alias-string cache parent is poison.** Spec D6: two pins of the
   same alias with different filesystems must not share
   `parent_layer_id`. Today the orchestrator passes the name as the
   layer id. In-place v0 rebuild of the alias makes this live.
4. **Refuse:** folding unimplemented pin/alias SHALLs (and the
   still-false deploy-default SHALL) into `openspec/specs/` before
   the act that makes them true. 2026-08-16 learning.
5. **Tradeoff I would price:** four independent debootstraps vs a
   FROM-ubuntu flavor DSL. Copy-paste is how `ci-ubuntu-24.04` went
   unreproducible last time.

## Compare / steelman

Every blind item is a question the author already answered.

- **(1)** Detector already emits `"mise install"` as step 1
  (`detector.ex:100`), `plan_to_steps` classifies `mise*` as
  `:runtime` (`orchestrator.ex:274`), ubuntu recipe already
  `install_mise` (`build-rootfs-ubuntu-24.04.sh:187`). The deploy
  guide already maps `FROM node:…` → `@base/ubuntu-24.04` + mise
  layer. The flip itself is out of scope here
  (`remove-deploy-node-bun`, `mjolnir-b0gb.2`). Plumbing predates
  the ADR. Cache-miss of old `deploy-node-bun`-parented layers is
  named in Risks and accepted.
- **(2)** `scripts/lib/guest-agent.sh:60-155` is the post-condition
  (binary + unit + `basic.target.wants`, `verify_guest_agent` fails
  the build, `ALLOW_NO_AGENT=1` opt-out). Inject is still a refresh
  when `:guest_agent_bin` exists (`vm.ex:2227-2236`); config default
  is `nil` (`config.exs:76`). D5 rebuilds already ran with spawn
  probes (`tasks.md:14-19`). Sequencing is rebuild-then-contract,
  not the reverse.
- **(3)** `Builder.build/3` defaults `:base_image` to `base_layer_id`
  (`builder.ex:102`); orchestrator passes the name (`orchestrator.ex:122`).
  D6 states this literally and scopes the fix to `add-base-image-pins`
  (`mjolnir-b0gb.6`), gated before a second tenant. v0 in-place is
  accepted because there is one tenant. Named bead, named trigger.
- **(4)** `tasks.md:25-29` already carves fold: architecture-only
  SHALLs that are true of the design, no unimplemented HTTP. Same
  guard must apply to the D6 pin scenarios and the deploy-default
  scenario — both are still false of the running system.
- **(5)** D4 prices copy-paste and rejects FROM-ubuntu on the
  rebuild-invalidation argument (OS roots have no layer cache).
  Bought with eyes open.

The load-bearing claims are descriptions of shipped code, not
aspirations. Cited lines match. I concur with the prior reads on
nuke-after-delete (Fable 1), v0 spawn-outage window (Fable 2), and
the D2×D6 pin/unmanaged taxonomy (Fable 3). None is send-back on
this write.

## Carried nits (notes, not blockers)

Directed at later nodes. None gates `accept`.

- **N1 (for `mjolnir-b0gb.2`).** Deleting `@base/deploy-node-bun`
  breaks L5 nuke for any VM whose StateStore `spawn_config` still
  records that `base_image` (`health.ex:440-455` → `BTRFS.clone`).
  Sweep or document loud nuke failure before the subvolume goes.
- **N2 (for `mjolnir-b0gb.6`).** A pin under `@base/`
  (`ubuntu-24.04-20260827`) is not in the catalog-v1 table, so D2
  letter-reads it as unmanaged. That collides with later pin GC.
  Treat recipe-produced pins as declared-archived. `tasks.md:48-51`
  already reserves `kind`/`resolves_to`.
- **N3 (fold).** Do not import the deploy-default scenario or the
  pin/alias SHALLs into living specs until the act that makes them
  true. The change-delta may hold them; fold may not.
- **N4 (arch recipe vs D3).** Fable claimed all four catalog recipes
  share the helpers. False for `arch`. `scripts/build-rootfs-arch.sh`
  sources only `terminfo.sh`. Agent install is inline
  (`build-rootfs-arch.sh:162-189`): warning, not `verify_guest_agent`
  fail-closed, if `AGENT_BIN` is missing. mise is `curl | sh` +
  `profile.d`, which is the exact non-login PATH trap `mise.sh`
  exists to close. Spec D4's helper-share SHALL lists ubuntu / CI /
  buzz only, so this is not a spec contradiction — but D3 applies
  to every declared name, and `arch` is in the v1 table. Convert
  the arch recipe to `install_guest_agent` + `install_mise` before
  the next `just deploy-rootfs distro=arch`. Live D5 probe already
  passed; this bites the next rebuild, not tonight.
- **N5 (`ubuntu-latest`).** D6 names `ubuntu-latest` as a channel.
  Catalog v1 does not. It is Docker-shaped illustration, not a
  fifth declared name. Do not implement a second alias without
  amending ADR 0009.

## Bottom line

Architecture is sound, internally consistent, and grounded in live
code. Scope boundaries are clean. Every deferral is a named bead
with a trigger. The new nit (arch helper gap) is a leftover of the
copy-paste D4 already priced, not a hole in the decisions.
**Accept.** No owed boxes added to `tasks.md`.
