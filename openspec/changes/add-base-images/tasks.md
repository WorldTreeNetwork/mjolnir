# Tasks

Architecture artifacts for `add-base-images`. Orchestrator default,
listing API, and doctor are later landings after advise accept.
Grok authored. Human accepted D1–D4 2026-08-27 and added D5
then D6 (pins + aliases).
Fable 5 is still the cross-family reader for code landings.

- [x] Write `design.md` (D1–D4)
- [x] Write ADR index `docs/decisions/0009-base-image-catalog.md` as Proposed
- [x] Delta `specs/base-images/spec.md` (ADDED)
- [x] Human accept D1–D4; add D5 (rebuild declared live images)
- [x] Human D6: pins immutable, aliases move (plan; `mjolnir-b0gb.6`)
- [x] Snapshot live declared `@base/` into `@snapshots/<name>-pre-rebuild-20260827`
- [x] Rebuild `ubuntu-24.04` from current recipe + current agent; spawn probe
      (`6be8cfa3`, vsock exec, agent md5 `8c3e7794`, mise 2026.8.14; killed)
- [x] Rebuild `ci-ubuntu-24.04` (rustc 1.98.0, zig 0.16.0, runner uid 1000),
      `buzz-agent` (sprig + goose), `arch` (Arch Linux, agent active).
      Probes killed. `deploy-node-bun` and `tatastu-agent` not rebuilt.
- [x] Advise accept from a non-Grok reader for the *code* landings
      (retire / list / health) — Fable accept-with-nits
      `reviews/2026-08-28-fable-advise.md`
- [x] After accept: pointer in `docs/architecture.md` Filesystem
      section (do not delete prior layout text)
Fold split (Fable 2026-09-10 finding 3). Folder does not decide
which SHALLs are "already true" — this table does. Do not import
unimplemented HTTP or pin resolver into living specs
(learning 2026-08-16).

| Requirement / scenario | Fold | Waits on |
|---|---|---|
| Catalog definition; unmanaged; pin is declared (archived) | fold-now (rule) | `add-base-image-list` for the list surface |
| Spawn default | fold-now | — |
| Deploy default; Node deploy uses ubuntu + mise | PENDING | `remove-deploy-node-bun` |
| Snapshot is not a catalog entry | fold-now (rule) | `add-base-image-list` for listing |
| Toolchains are not OS roots (review reject) | fold-now | — |
| Recipes SHALL NOT produce `deploy-node-bun` | PENDING | `remove-deploy-node-bun` |
| Catalog image boots without inject | fold-now | — |
| Declared live images match recipes (v0 + drop all deploy-* layers) | fold-now | — |
| Retired image is not rebuilt | fold-now | `remove-deploy-node-bun` for the delete |
| Pins are immutable; aliases move | PENDING | `add-base-image-pins` |
| Flavors are independent recipes | fold-now | — |

Owed from advise send-back `reviews/2026-09-10-advise.md`
(Fable 5.1, cross-family; binary verdict replacing the two
`accept-with-nits` above). D1–D6 stand; these are delta/ADR text:

- [x] Finding 1: `scripts/build-rootfs-arch.sh` sources
      `scripts/lib/guest-agent.sh` and calls `install_guest_agent`
      (verify is inside the helper). D3 SHALL stays over all
      declared names including `arch`.
- [x] Finding 2: catalog requirement + ADR 0009 D2 — a pin
      produced by a declared alias's recipe is declared (archived),
      not unmanaged; unmanaged is a name with no recipe in this repo.
- [x] Finding 3: fold-gate table above.
- [x] Finding 4: D5 operator sequence step 5 + ADR D5 — after an
      in-place alias rebuild, delete `@snapshots/deploy-*` layers
      whose cache parent is that alias.
- [x] Re-advise (cross-family) after the four above
      (`reviews/2026-09-10-readvise.md`).

Owed from re-advise `reviews/2026-09-10-readvise.md` (Fable 5.1,
cross-family; send-back on the finding-4 wording, which the prior
review itself mis-specified). D1–D6 stand:

- [x] Finding 1: D5 v0 cache drop → delete *every* `@snapshots/deploy-*`
      layer after an in-place alias rebuild, via `mj snapshot rm` /
      `DELETE /api/snapshots/:name` (sidecar included; not raw
      `btrfs subvolume delete`). D6 removes the step.
- [x] Finding 2: split fold row — review-reject fold-now; "Recipes
      SHALL NOT produce `deploy-node-bun`" PENDING on
      `remove-deploy-node-bun`.
- [x] Ride-along: "bootstrap recipes" (debootstrap or pacstrap).
- [x] Re-advise (cross-family) after the three above
      (`reviews/2026-09-10-readvise2.md`, accept).

Handoffs (not checkboxes):

- Rebuild declared images (`mjolnir-b0gb.5`) — D5 operator landing
  on this change. Not `deploy-node-bun`. Not `tatastu-agent`.
- `remove-deploy-node-bun` (`mjolnir-b0gb.2`) — Orchestrator
  default `ubuntu-24.04`; delete `scripts/build-deploy-base.sh`;
  delete live `@base/deploy-node-bun`. Supersedes `mjolnir-gge.1.10`
  and `mjolnir-bhcr`.
- `add-base-image-list` (`mjolnir-b0gb.3` / `mjolnir-8vo`) —
  `GET /api/base-images` + `mj bases`; unmanaged vs declared.
- `add-base-image-health` (`mjolnir-b0gb.4` / `mjolnir-pj6t` /
  `mjolnir-hjnz`) — doctor + noisy inject.
- `mjolnir-6ee1` — `--base` / `mjolnir.toml` override; lands with
  the retire node, not a fourth catalog name.
- `@base/dev` convergence — Buzz design Decision 6, later.
- Recipe DSL unification — later refactor, not catalog v1.
- `add-base-image-pins` (`mjolnir-b0gb.6`) — D6. Recipe writes a
  pin, retargets the alias, record pin on deploy, cache parent is
  the pin. Before a second tenant. `mj bases` should leave room
  for `kind` / `resolves_to` so list does not freeze aliases as
  identity. `@base/` has no sidecar; "produced by that recipe" is
  a filename regex until pins land — note for list + pins.
