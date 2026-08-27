# Tasks

Architecture artifacts for `add-base-images`. Orchestrator default,
listing API, and doctor are later landings after advise accept.
Grok authored; advise reader must not be Grok (ADR-005). Fable 5
is the cross-family reader. Sol is not subscribed.

- [x] Write `design.md` (D1–D4)
- [x] Write ADR index `docs/decisions/0009-base-image-catalog.md` as Proposed
- [x] Delta `specs/base-images/spec.md` (ADDED)
- [ ] Advise accept from a non-Grok reader
- [ ] After accept: pointer in `docs/architecture.md` Filesystem
      section (do not delete prior layout text)
- [ ] Fold deltas into `openspec/specs/base-images/` only when the
      first implementing act has landed (retire), or fold
      architecture-only SHALLs that are already true of the design
      (do not import unimplemented HTTP into living specs —
      learning 2026-08-16)

Handoffs (not checkboxes):

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
