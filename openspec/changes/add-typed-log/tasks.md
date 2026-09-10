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
- [ ] Amend (1): pin discriminator — `:app_log` iff MSG is a JSON
      object with `schema`, regardless of `source`; `source` is a
      stamp (design D3, spec ingest requirement)
- [ ] Amend (2): resolve the unix-datagram/UDP hedge to UDP —
      loopback port on host, `10.200.0.1` from guests; target is
      explicit config, unset = stdout only. Node/bun have no AF_UNIX
      datagram API (design D3, spec ingest requirement, steer note)
- [ ] Amend (3): either pin RFC 3164 on the wire for v1 or add
      "RFC 5424 header parse" to the `add-log-ingest` handoff
      (parser handles 3164 only; design D2 says 5424 preferred)
- [ ] Amend (7): align `proposal.md` Empty/Impact lines to this file —
      fold does not create `openspec/specs/typed-log/` from this
      change (learning 2026-08-16)
- [ ] Amend (8): correct ADR 0010 + design "Built" — guest forwarder
      built; host never registers ch2 (`Listener.register_connection/3`
      has no caller, `:vm_spawned` unmatched) and multi-VM sender id
      drops all data. Give that work a home (ingest or own bead)
- [ ] Scope lines for ingest/subscribe (from advise (4)(5)(6)(9)):
      max record size + oversize-as-malformed; app id is self-asserted;
      `:all` receives app logs (or distinct `:pg` group); `:app_log`
      default sinks `[:eventbus]` with level from pino `level`
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
