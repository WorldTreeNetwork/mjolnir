# Tasks

Architecture artifacts for `add-mailbox-durable-accept`. Code is
`act` after advise accept. Grok authored; advise reader must not be
Grok (ADR-005). Fable 5 is the cross-family reader. Sol is not
subscribed.

- [x] Write `design.md` (decisions)
- [x] Write ADR index `docs/decisions/0006-mailbox-as-spool.md` as Proposed
- [x] Delta `specs/vm-mailbox/spec.md` (ADDED)
- [x] Advise accept (Fable) — `reviews/2026-08-22-advise.md` (accept-with-nits)
- [ ] After accept: `act` host `Mjolnir.Mailbox` + API `id` + unify
      the three queues + startup sweep + give-up (`mjolnir-5le4.1`).
      Absorb advise nits: fsync the parent directory after rename
      (Forge.Store does not; qmail does); exclusive create on
      message_id; delivery-worker ownership; tombstone retention;
      GC `@mail/` on `mj kill`.
- [ ] After accept: guest peek/ack (`mjolnir-5le4.2`; may weave)

Handoffs (not checkboxes):

- `mjolnir-5le4.4` — Admit seam / future proxy as mailbox **reader**
- Multi-host placement directory — named in Decision 7, not this act
- Competing-consumer table — not until PUSH/PULL is real
