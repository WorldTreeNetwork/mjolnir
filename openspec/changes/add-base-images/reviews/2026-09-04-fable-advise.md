# add-base-images — architecture advise (fable-5.1, other-family)

> **ADVISE:** accept
> **READER:** fable-5.1-arch-review
> **SPAWN:** /home/dorje/work/IdentiKey/mjolnir/.spawns/advise-add-base-images-fable-1788535586-453938-91614d36

**Author:** Grok 4.6. **Reader:** fable-5.1-arch-review (other-family,
`claude` harness, effort high). Verdict is on the architecture write
(ADR 0009 D1–D6 + `specs/base-images/spec.md` delta), not on the
unwritten retire / list / health / pins code.

**Prior reads (not overwritten):** human accept-with-nits
(`2026-08-27-human-advise.md`); Fable 5 accept-with-nits
(`2026-08-28-fable-advise.md`); opus-4.8 accept (`2026-09-04-advise.md`);
sol accept (`2026-09-04-sol-advise.md`). I did not concur by
reference; every claim below was re-verified against the tree.

## Blind take (written before design.md / tasks.md)

1. Pin: one default. Orchestrator's `@default_base_image` must read
   `:default_base_image` from config, not carry a second literal. Two
   literals is exactly how `deploy-node-bun` vs `ubuntu-24.04` drifted.
2. Pin: "declared" must be a machine-readable list, because "unmanaged"
   is a diff against it. Prose in ADR 0009 cannot classify a subvolume.
3. Pin: by the spec's own definition, `arch` and `buzz-agent` are
   declared only if a recipe exists in-repo.
4. Refuse: any FROM-ubuntu DSL, any `@base/deploy-<lang>`, any
   auto-delete of unmanaged subvolumes.
5. Concern: v0 in-place alias rebuild with a deploy cache whose parent
   is the alias *string* means cached layers keep the pre-rebuild
   filesystem. Was the cache invalidated on 2026-08-27, or is that
   silently stale?
6. Concern: `inject_guest_agent` as "refresh" can downgrade if the
   host's `:guest_agent_bin` is older than the agent the recipe baked.
7. Concern: `ALLOW_NO_AGENT=1` must not be reachable from any default
   path (Justfile, deploy.sh).
8. Concern: anything that re-clones from the alias by name later
   (nuke/respawn, redeploy) silently gets a different tree.
9. Tradeoff: in-place alias replace now vs pins now. Right cost while
   single-tenant, only if v1 is a real gate before a second tenant.
10. Concern: `ci-ubuntu-24.04` builds via a separate Justfile path; the
    D5 rebuild must include it or "declared live images match current
    recipes" is false for CI.

## Compare / steelman

Every blind item is a question the author answered, or a prior reader
already carried to the right act node. Verified against code:

- **(1)** Out of scope here by design; `remove-deploy-node-bun`
  (`mjolnir-b0gb.2`) flips it. Implementer note below: flip to the
  config read, not to a second literal.
- **(2)** Prior Fable already owes this to `add-base-image-list`.
  tasks.md reserves `kind` / `resolves_to`. Answered.
- **(3)** All four v1 names have recipes: `build-rootfs-ubuntu-24.04.sh`,
  `build-ci-image.sh`, `build-buzz-agent-image.sh`, `build-rootfs-arch.sh`.
  `tatastu-agent` has none; `deploy-node-bun` has `build-deploy-base.sh`
  scheduled for deletion. D2's table is honest.
- **(4)** All three refusals are SHALLs in the delta with
  reject-on-review scenarios. Nothing in tasks.md violates them.
- **(5)** Confirmed: `Builder.build/3` defaults `base_image` to
  `base_layer_id` (`builder.ex:102`) and `CacheKey.compute/3` hashes
  `parent_layer_id` as a plain string. D6 names this ("cache poison")
  and scopes the fix to `mjolnir-b0gb.6`. **Latent today**: the
  orchestrator still defaults `deploy-node-bun`, so no layer chain is
  rooted at `ubuntu-24.04` yet. See N1 for the v0 consequence nobody
  has stated.
- **(6)** `inject_guest_agent/1` (`vm.ex:2227`) is an unconditional
  `File.cp!` when the path exists, no version check. But
  `config/prod.exs:6` and the Justfile `deploy-rootfs` recipe
  (`Justfile:137`) name the **same** path, so the baked agent and the
  refresh source are one file. Downgrade needs an operator to build
  an image from a different `AGENT_BIN`. Answered by convention, not
  contract; see N3.
- **(7)** `ALLOW_NO_AGENT` appears only in `scripts/lib/guest-agent.sh`
  and the ubuntu recipe's comment. Not set by Justfile or deploy.sh.
  Answered.
- **(8)** Prior Fable finding 1 (nuke/respawn after subvolume delete)
  covers the retire half; D6 covers the redeploy half. Answered.
- **(9)** D6 is bound to `mjolnir-b0gb.6` "before a second tenant" with
  a human date. Named bead, named trigger. Answered.
- **(10)** design.md D5 step 3 lists `just build-ci-image` and
  `build-buzz-agent-image` alongside `deploy-rootfs`; tasks.md records
  all four rebuilt with probes. Answered.

Steelman of the whole: the strongest argument against is that D1 turns
an offline-reliable first deploy into a network-dependent one. Prior
Fable priced that and the answer holds: the baked image already gave
the worse failure (`:boot_timeout`, mjolnir-bhcr) and moved the fetch
to a build nobody remembers how to run.

## Findings (notes; none is send-back grade)

- **N1 (new; for the D5 runbook and `mjolnir-b0gb.6`). A v0 in-place
  rebuild does not propagate to cached deploy layers.** Because the
  cache parent is the alias string, every existing `deploy-*` layer
  rooted at `ubuntu-24.04` stays a cache hit after the alias is
  replaced. Redeploys then boot the pre-rebuild filesystem, including
  the pre-rebuild agent, via cache hits. D5's "declared live images
  match current recipes" is true of `@base/` and false of what deploy
  actually boots. This is the operational flip side of D6's
  "cache poison" and is not stated anywhere. Latent until the retire
  flip lands; live at the first v0 rebuild after it. Cheap v0 answer
  for the runbook: after an in-place rebuild, delete `deploy-*`
  layers whose chain roots at the rebuilt name, or say out loud that
  cached apps stay stale until D6. D6 fixes it structurally (new pin
  → new key).
- **N2 (concur; for `mjolnir-b0gb.2`).** Flip `@default_base_image`
  (`orchestrator.ex:50`) to
  `Application.get_env(:mjolnir, :default_base_image)`, not to a
  second `"ubuntu-24.04"` literal. The spec's "default for both" is a
  single-source claim; two literals will drift again.
- **N3 (for `mjolnir-b0gb.4`).** The refresh contract is safe only
  because prod's `:guest_agent_bin` and the recipe's `AGENT_BIN` are
  the same path by convention. Health should assert that, or compare
  the hash of the baked agent to the host binary, so an image built
  from a different `AGENT_BIN` is reported rather than silently
  downgraded at every spawn.
- **N4 (concur with sol N4).** `build-rootfs-arch.sh` sources only
  `terminfo.sh`; agent install is inline and conditional
  (`arch:163-186`), mise is `curl | sh` + `profile.d` (`arch:260-267`).
  D3 applies to every declared name and `arch` is in the v1 table.
  Not a spec contradiction, but the next `just deploy-rootfs distro=arch`
  should go through `install_guest_agent` + `install_mise`.
- **N5 (concur with prior Fable 2 / opus N4).** The ubuntu recipe
  deletes then creates the live name (`build-rootfs-ubuntu-24.04.sh:53,58`)
  with no snapshot step of its own; D5 step 1 is manual. Spawn-outage
  window for a debootstrap. Structurally fixed by D6.
- **N6 (fold discipline).** The deploy-default scenario and the D6
  pin/alias SHALLs are true of the design, not of the system.
  tasks.md's fold guard already says this; apply it to both.

## Bottom line

Architecture is sound, grounded in shipped code, and every deferral is
a named bead with a trigger. The one new finding (N1) is a runbook
gap on an operator landing, not a defect in D1–D6. **Accept.** No owed
boxes added to `tasks.md`.
