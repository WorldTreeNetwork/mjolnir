# Design — mailbox as a per-actor spool

Canonical ADR index:
[`docs/decisions/0006-mailbox-as-spool.md`](../../../docs/decisions/0006-mailbox-as-spool.md).
This file is the full argument. The essay that must survive a closed
session is
[`docs/philosophy/mailbox-as-spool.md`](../../../docs/philosophy/mailbox-as-spool.md).

**Status:** Accepted (advise accept-with-nits 2026-08-22). ACTIVE BUILD.
**Change:** `add-mailbox-durable-accept`
**Epic:** `mjolnir-5le4`
**First consumer:** Tatastu Cloud / Continue (`POST /api/vms/:id/messages`).

## Problem

Four questions after intend:

1. Is 200 “accepted for delivery” or “the producer may forget”?
2. Does durability live in a front-proxy VM, Postgres, or the
   filesystem?
3. Are running / booting / dormant allowed to mean different things?
4. How do 0MQ / π-calculus patterns grow without a broker?

Fable consult (2026-08-21): the proxy is wake-policy (problem B),
being sold as delivery (problem A). A VM cannot be the accept point.

## Decision 1 — One spool, filename is identity

Every accepted message is a JSON file
`{btrfs_root}/@mail/<vm_id>/<message_id>.json`.

The producer supplies `id` (Tatastu may derive it from `runId`).
That string **is** the filename. A second POST of the same id is a
stat, not a second message: 200 `{status: "duplicate"}` if a live
file or an ACK tombstone exists.

If `id` is omitted, the host generates one and returns it. Retry
safety is then **off** unless the client echoes that id. Document
it; do not pretend.

Write path is `Forge.Store` / `StateStore`: tmp + `:file.sync` +
rename, then 200. Not `DormantRegistry` (`File.write`, no fsync,
250 ms debounce).

## Decision 2 — 200 is durable accept, not handled

Delivery is async. A coding turn can take minutes. 200 MUST NOT
wait for guest application ACK.

Non-200 or timeout → producer retries the identical POST.

Vsock `deliver_message` includes the producer id. Host delivery
worker reads the file and sends; it does not delete.

## Decision 3 — Two ACKs, sharply distinct

| ACK | Meaning | Deletes the file? |
|---|---|---|
| Vsock `deliver_message_ack` | Guest agent buffered in RAM (`VecDeque`) | **Never** |
| Application ACK | Guest recorded or processed the id; host may tombstone | Yes → `@mail/<vm_id>/acked/<id>` retained briefly so late retries stay duplicates |

Today’s guest HTTP `drain(..)` is destructive. The guest inbox
becomes peek, then an `ack_messages` control message. That
protocol is in this capability; implementing it is `act` (bead
`mjolnir-5le4.2` may land in the same act as the host store).

## Decision 4 — Unacked mail is the wake condition

`handle_done` does not barrier on the mailbox. A POST that races
dormancy is already on disk. The delivery worker finds a dormant
VM with unacked files and uses the existing restore path (subject
to Admit). `take_pending_messages` must not clear-then-send.

Startup sweep (next to `Mjolnir.Cleanup`) redelivers every unacked
file. At-least-once; the guest is idempotent on `message_id`.

## Decision 5 — Admit rejects never-messages; thaw is after accept

Two different no’s:

- **Never a message** (unsigned, forbidden, not a VM): 4xx/404, **no
  file**. Producer must not forget.
- **Valid message, don’t thaw** (Buzz I5, `:never`, policy): 200
  queued. Delivery worker does not restore. File waits.

Tatastu `type: turn` always thaws after accept. Do not put policy
in the 200 meaning.

A future tenant-policy VM, if any, **reads** the spool after fsync.
It is not the accept point (`mjolnir-5le4.4`).

## Decision 6 — Filesystem ledger; Postgres is not the queue

Host control-plane source of truth is already files (`StateStore`,
`Forge.Store`, `SecretStore`). The sidecar is derived indexes
(ADR 0005 catalog / hotel does not change this). Same disk, same
crash domain; `:pg_enabled` is off by default.

Postgres earns a table the day two workers **claim** from one pile
(0MQ PUSH/PULL). Not v1.

A later derived index of `@mail/` for operator UI is allowed. 200
still waits on the file.

## Decision 7 — Placement is not the queue

Multi-host: lookup which host owns the VM (tiny derived directory;
PG is fine *there*), accept on that host’s `@mail/`. The spool
migrates with the actor (`btrfs send`). Wrong-host POST forwards.
Do not dual-write. Not built in this change.

## Decision 8 — Give-up / bounce

A wedged guest must not fill the disk. After a documented TTL or
max delivery attempts the host moves the file to a bounce/dead
area and stops waking. The 200 already happened; this is operator
visible, not a silent drop of an un-accepted message.

## Decision 9 — Compose above the spool

0MQ patterns (REQ/REP, PUB/SUB, ROUTER/DEALER) are GenServers that
send to names. They are not a second store. PUSH/PULL competing
consumers are shared claim state — later, not this ledger.

## Rejected

- Per-workspace always-on proxy VM as the mailbox
- NATS / SQS / Kafka as the ledger
- EventBus persistence
- Guest-visible virtio-fs maildir in v1
- Waiting on `mjolnir-3y6` freeze/thaw
- SQS-style visibility timeout (one consumer per mailbox)

## Current traps this change deletes (after act)

- Running vsock **cast** as 200 (`vm.ex` ~1130)
- Boot in-memory `message_queue` (`finish_boot` drain)
- Dormant `pending_messages` without fsync
- `take_pending_messages` then send
- `:restoring` reject + `retry_deliver_message` 5×200 ms
- Guest `drain(..)` as the only copy

## Implement after accept

Host store + unify queues + API `id` + startup sweep + give-up:
`mjolnir-5le4.1` / this change’s `act`.

Guest peek/ack: `mjolnir-5le4.2` (may weave in the same act).

`signal_done` wake-on-unacked-mail: `mjolnir-5le4.3` (falls out of
Decision 4 if take-then-send is gone).
