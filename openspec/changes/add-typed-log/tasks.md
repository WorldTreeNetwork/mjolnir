# Tasks

Architecture artifacts for `add-typed-log`. Package/socket/LSP are
later landings after advise accept. Grok authored; advise reader
must not be Grok (ADR-005). Fable 5.1 is the cross-family reader.

- [x] Steer recorded (`steer.md`); activate all; remaining forks
      took recommended options
- [x] Write `design.md` (decisions)
- [x] Write ADR index `docs/decisions/0010-typed-log.md` as Proposed
- [x] Delta `specs/typed-log/spec.md` (ADDED)
- [x] Advise accept (Fable 5.1) — `reviews/2026-09-10-advise.md`,
      `READER: fable-5.1-arch-review` (ADR-005). Accept with the
      amendments below; (1)–(3), (7), (8) gate emit/ingest activation.
- [x] Amend (1): pin discriminator — `:app_log` iff MSG is a JSON
      object with `schema`, regardless of `source`; `source` is a
      stamp (design D3, spec ingest requirement)
- [x] Amend (2): host ingest is UDP — loopback port on host,
      `10.200.0.1` from guests; unset = stdout only
- [x] Amend (3): v1 wire is RFC 3164 (parser we have); 5424 is not v1
- [x] Amend (7): proposal Empty/Impact — this change folds ADR only
- [x] Amend (8): Built = guest forwarder; ch2 register + multi-VM
      sender id is `add-log-ingest`
- [x] Scope lines for ingest/subscribe: 64 KiB max; app id
      self-asserted; `:all` gets app logs unless distinct `:pg`
      group; `:app_log` sinks `[:eventbus]`
- [x] After accept: pointer in `docs/architecture.md` (do not delete
      prior ADR text)
- [ ] Fold ADR-only; living `openspec/specs/typed-log/` waits on
      first implementing act (learning 2026-08-16)

Handoffs (not checkboxes; activated, blocked on advise accept):

- `add-log-emit` — bun package, pino, stdout + syslog, pretty/plain
- `add-log-ingest` — host UDP + RFC 3164 JSON MSG + ch2 register +
  multi-VM sender id + `:app_log` discriminator
- `add-log-subscribe` — EventBus topic helpers / docs
- `add-log-lsp` — schema-driven language server
- `add-myscape-log-types` — first type file + wiring
