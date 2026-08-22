# add-mailbox-durable-accept

> **ACTIVE BUILD**
>
> Folded 2026-08-22 → `openspec/specs/vm-mailbox/spec.md`.

Activated from intend 2026-08-21 (`nod-mailbox-durable-accept`,
“let's roll through”). Philosophy:
[`docs/philosophy/mailbox-as-spool.md`](../../../docs/philosophy/mailbox-as-spool.md).
Epic `mjolnir-5le4`.

**Rigor:** architecture

## Why

`POST /api/vms/:id/messages` looks like a work queue. It is a
best-effort wakeup channel: 200 is not durable accept, running /
booting / dormant have different semantics, and a closed laptop
cannot tell drop from duplicate. Guest `runId` cannot resurrect a
host drop. A front-proxy VM cannot honestly 200 without writing host
disk.

## What

- Add capability `vm-mailbox`: per-actor filesystem spool, producer
  `message_id` is the filename, 200 only after tmp+rename+fsync,
  one queue for every VM state, vsock ACK is a hint, application
  ACK tombstones, unacked mail is the wake condition, documented
  give-up.
- Accept ADR 0006 (`docs/decisions/0006-mailbox-as-spool.md`, full
  text in `design.md`).
- This change is the architecture write (ADR + deltas). Code is
  `act` after advise accept.

## Impact

- Capabilities: ADDED `vm-mailbox` (materialized by fold)
- ADRs: 0006 (this change). Pointer from `docs/architecture.md`
  Channel System (already names the philosophy file).
- Does not rewrite ADR 0002 (OTP mailboxes are the queue; Admit is
  the facade). This change is the durability of that queue.

## User journey & surfaces

No new UI because the outcome already reaches
`POST /api/vms/:id/messages` and `mj message`.

Tatastu (or a human) hits Cloud / Continue:

- **Working (after act)** — 200 `{ok, message_id, status:
  queued|duplicate}`; laptop may close; the turn runs once.
- **Empty** — `openspec/specs/vm-mailbox/` does not exist yet.
  Correct: fold creates it.
- **Failed (today)** — 200 then silent drop on a running VM; retry
  is an extra turn; `signal_done` races lose RAM inbox.
- **Off** — Duke parks. The ADR is amended in place, not deleted.

## Out of scope

- Per-workspace front-proxy VM — philosophy file; bead `mjolnir-5le4.4`
  is a later Admit *reader* seam, not this accept path
- Postgres as the ledger — sidecar stays derived indexes (ADR 0005)
- EventBus persistence
- Guest-visible maildir mount
- Memory freeze/thaw (`mjolnir-3y6`)
- Competing-consumer claim / PUSH/PULL
- Multi-host placement directory — named in the ADR, not built here
- Payload schema (`type: turn` is the guest's)
