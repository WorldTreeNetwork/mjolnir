# Tasks

Architecture artifacts for `add-typed-log`. Package/socket/LSP are
later landings after advise accept. Grok authored; advise reader
must not be Grok (ADR-005). Fable 5.1 is the cross-family reader.

- [x] Steer recorded (`steer.md`); activate all; remaining forks
      took recommended options
- [x] Write `design.md` (decisions)
- [x] Write ADR index `docs/decisions/0010-typed-log.md` as Proposed
- [x] Delta `specs/typed-log/spec.md` (ADDED)
- [ ] Advise accept (Fable 5.1) — `reviews/<date>-advise.md` with
      `READER:` (ADR-005)
- [ ] After accept: pointer in `docs/architecture.md` (do not delete
      prior ADR text)
- [ ] After accept: fold deltas into `openspec/specs/typed-log/`
      only when the first implementing act has landed, or fold
      architecture-only SHALLs that are already true of the design
      (do not import unimplemented npm/host-socket into living
      specs — learning 2026-08-16)

Handoffs (not checkboxes; activated, blocked on advise accept):

- `add-log-emit` — bun package, pino, stdout + syslog, pretty/plain
- `add-log-ingest` — host unix datagram + JSON MSG parse + `:app_log`
- `add-log-subscribe` — EventBus topic helpers / docs
- `add-log-lsp` — schema-driven language server
- `add-myscape-log-types` — first type file + wiring
