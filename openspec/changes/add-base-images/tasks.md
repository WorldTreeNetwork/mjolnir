# Tasks

Architecture artifacts for `add-base-images`. Orchestrator default,
listing API, and doctor are later landings after advise accept.
Grok authored. Human accepted D1–D4 2026-08-27 and added D5.
Fable 5 is still the cross-family reader for code landings.

- [x] Write `design.md` (D1–D4)
- [x] Write ADR index `docs/decisions/0009-base-image-catalog.md` as Proposed
- [x] Delta `specs/base-images/spec.md` (ADDED)
- [x] Human accept D1–D4; add D5 (rebuild declared live images)
- [ ] Snapshot live declared `@base/` into `@snapshots/<name>-pre-rebuild-20260827`
- [ ] Rebuild `ubuntu-24.04` from current recipe + current agent; spawn probe
- [ ] Rebuild `ci-ubuntu-24.04`, `buzz-agent`, `arch` the same way
- [ ] Advise accept from a non-Grok reader for the *code* landings
      (retire / list / health)
- [ ] After accept: pointer in `docs/architecture.md` Filesystem
      section (do not delete prior layout text)
- [ ] Fold deltas into `openspec/specs/base-images/` only when the
      first implementing act has landed (retire), or fold
      architecture-only SHALLs that are already true of the design
      (do not import unimplemented HTTP into living specs —
      learning 2026-08-16)

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
