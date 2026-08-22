# Mailbox as spool

**Status:** Folded 2026-08-22. ADR
[`0006`](../decisions/0006-mailbox-as-spool.md). Living spec
[`vm-mailbox`](../../openspec/specs/vm-mailbox/spec.md).
**Tracker:** beads epic `mjolnir-5le4`.
**Consult:** Fable 5 plan pass 2026-08-21. Memory key `mailbox-retry-safe`.

This is the durable copy of the retry-safe mailbox argument: why a
per-actor filesystem spool is the primitive, why a front-proxy VM is
not, and how 0MQ / π-calculus patterns compose *above* that spool
without a broker.

What shipped is [`../vm-messaging.md`](../vm-messaging.md). This file
is the argument, not the SHALL store.

---

## Why this file exists

Tatastu’s Cloud button is `POST /api/vms/:id/messages` and then the
laptop may close. If the host 200s and then drops the turn, the chat
looks sent and never ran. If the same POST is retried after a timeout,
the agent may commit, deploy, or email twice.

Guest-only `runId` dedupe cannot resurrect a drop. True broker
exactly-once (leases, 2PC) is the wrong weight. The product name is
exactly-once; the primitive is **retry-safe at-least-once** plus an
idempotent consumer.

## Two problems that got fused

| | A. Retry-safe delivery | B. Wake policy |
|---|---|---|
| Question | Can the producer forget after 200? | Do we thaw a fat VM for junk? |
| Right layer | Host durable log | Host facade / `Mjolnir.Admit` |
| Front-proxy VM? | No — it cannot be the accept point | Maybe later, as a **reader** of the log, if policy is tenant-authored Linux |

ADR 0002 already put B on the host: admit, then thaw;
`deliver_message` is the trusted hop. A per-workspace always-on proxy
VM does not make 200 honest. A VM’s inbox is RAM plus a rootfs this
system *deletes* on dormancy. For a proxy to ACK durably it must write
host disk — at which point the disk write is the mechanism and the VM
is turtles (who queues while the proxy boots?). N always-on VMs also
fight the dormancy cost model. Blob-door already litigated the shape:
host sidecar, not a VM.

If tenant wake policy ever ships, order is: **host accepts durably,
then policy decides whether to thaw.**

## The primitive

A named channel you can send to. 200 only after the bytes are on disk.
Retries of the same name are the same send. π-calculus `c⟨v⟩` plus
SMTP’s 250-after-fsync.

v1 shape, when built:

- One JSON file per message: `@mail/<vm_id>/<message_id>.json`
- Write path copied from `Forge.Store` / `StateStore` (`tmp` +
  `:file.sync` + rename), **not** from `DormantRegistry` (`File.write`,
  no fsync, 250 ms debounce)
- Filename **is** the producer-id index. Do not add a lookaside that
  can disagree with the queue
- 200 = fsync done. Delivery is async (a turn can take minutes)
- Vsock `deliver_message_ack` is a RAM hint. It must never delete mail
- Guest drain becomes peek-then-ack. Host tombstones only on
  **application ACK**
- Unacked mail **is** the wake condition. A POST that races
  `handle_done` survives on disk and restores the VM
- Documented give-up / bounce (TTL or max attempts) so a wedged guest
  cannot fill the disk — early MTAs had this

This is a **per-actor spool**, not a cluster bus. Queue depth for
Tatastu is about one. The load that matters is VM wake (seconds), not
fsync (~1 ms).

## Why filesystem, not the Postgres sidecar

Postgres is a better *queue engine* (`UNIQUE`, `SKIP LOCKED`,
`LISTEN/NOTIFY`). Filesystem is the better *accept point on this host*.

- **Same crash domain.** The sidecar is an OTP Port; WAL sits on the
  same disk as `@mail/`. Disk loss kills both. Off-box copy is
  `btrfs send` (`mjolnir-qwp`), which already knows subvolumes. A
  mailbox directory rides that; a PG table needs dump/restore.
- **200 is source of truth, not an index.** Control-plane contract:
  FS first, Postgres is derived and rebuildable (`sites.head_index`,
  …). Host operational state already follows that rule: `StateStore`,
  `DormantRegistry`, `Forge.Store`, `SecretStore`. If the mailbox lives
  *only* in Postgres, you cannot rebuild unacked work from disk.
- **`:pg_enabled` is off by default.** Tests and Macs have no sidecar.
  A PG mailbox either silently degrades to today’s lossy path or you
  run two accept implementations.
- **Dual-write is the trap.** 200 after `INSERT` then best-effort
  file, or the reverse: one of those is a lie after a crash.

A `mailbox` schema on the catalog would not violate ADR 0005 (it is
not a tenant hotel). The objection is “this row is the only copy of
work the laptop already forgot.”

PG *as a derived index* of `@mail/` is fine later (operator UI, stuck
messages). 200 still waits on the file. Competing consumers — claim,
lease, fencing — are shared state; **that** is when the sidecar earns
its keep. Not as the ledger.

## What SQS FIFO actually upgraded

Standard SQS (2006): at-least-once, and the *broker itself* could
duplicate. Visibility timeout + delete. Consumer still idempotent.

FIFO (2016), marketed as “exactly-once processing,” added two things:

1. **Producer dedup.** `MessageDeduplicationId` (or SHA-256 of the
   body). Retry `SendMessage` within a **5-minute** window → API
   succeeds, no second message. That is our filename = `message_id`.
2. **The broker stops inventing duplicates**, plus order per
   `MessageGroupId`.

They did not add 2PC. They did not stop redelivery if the consumer
crashes after work and before `DeleteMessage`. AWS’s “exactly-once”
means: *retries of send don’t create two items, and we won’t fork the
item in the back end.* The consumer contract stayed at-least-once +
idempotent delete.

The 5-minute window is an AWS cost/state choice. A tombstone file can
live until ACK, or for days, for free — stricter than FIFO, cheaper
than their windowed index.

Lesson: the upgrade was **ingress identity + don’t let the store
duplicate.** Do not import leases or a second product named
exactly-once.

## Compose above the spool

ADR 0002: take 0MQ *patterns*, not libzmq. Channels compose because
**send-to-a-name** is the only disk primitive. A pipeline is a
GenServer that reads one mailbox and writes another.

| Pattern | What it is here |
|---|---|
| PAIR / named send | `POST …/messages` with `message_id`. v1. |
| REQ/REP | Send + wait for a reply on your own mailbox. Two spools. |
| PUB/SUB | One accept, then N sends to N mailboxes (or `:pg` fan-out). Durability is still per recipient. |
| ROUTER/DEALER | The host facade (Admit). Already designed. |
| PUSH/PULL (competing consumers) | A pool, a claim, fencing. Shared state. Sidecar table. Not `@mail/<vm_id>/`. |

Do not implement 0MQ on the disk layer.

## Multiple servers: placement is not the queue

Do not start with a shared queue. Start with a **directory**: which
host owns this VM?

```
POST /messages for VM X
  → lookup placement (tiny index; PG is fine *here*, it is derived)
  → durable accept on that host’s @mail/X/<id>
  → delivery worker on that host
```

Orleans: the grain directory is small and queryable; the grain’s
mailbox is local to wherever the grain is activated. When a VM
migrates, the spool moves with the subvolume (`btrfs send` / Iroh),
same as the rootfs. A cluster-wide Postgres queue would *decouple*
mail from the actor and then you invent claim, fencing, and “which
host may delete.”

Wrong-host POST: forward to the owner. Do not dual-write.

[`../actor-persistence.md`](../actor-persistence.md) already names
distributed activation this way. The mailbox must travel with the
actor, not precede it.

## What the code does today (the traps)

Three queues, none of them the same. The retry loop exists only
because of that.

- **Running** (`lib/mjolnir/vm.ex` ~1130): vsock **cast**. 200 means
  “enqueued a write.” Host does not wait for `deliver_message_ack`.
- **Guest ACK** (`native/mjolnir_guest_agent/src/vsock.rs` ~1085):
  pushed onto an in-memory `VecDeque`. Host treats ACK as a no-op.
- **Guest HTTP drain** (`agent.rs` `handle_messages`): `drain(..)`
  **destroys on GET**. App crash between GET and process loses the
  only copy.
- **Booting**: in-memory GenServer list. Lost on host crash. Zeroed
  at `finish_boot`.
- **Dormant**: one `registry.json` for all VMs, 250 ms debounce,
  `File.write` + rename with **no `:file.sync`**. Instant mode is
  still not fsync. Documented “queued on disk” oversells the 200.
- **Restore**: `take_pending_messages` **clears the queue**, then
  vsock-casts. Crash in that window is permanent loss.
- **Restoring**: reject + 5×200 ms retry races the flush → double
  send, no producer id.
- **`signal_done`**: filesystem snapshot only. The in-memory inbox
  is not in the snapshot. “Just finishing a turn” is the drop.
- **`build_running_record/1`**: wipes the runtime map on boot/resume.
  Mailbox state must not live only there.

The tell that the spool is the right missing layer: `retry_deliver_message`,
the `:restoring` reject, and `finish_boot`’s drain loop become
**deletable**.

## What not to build

- Per-workspace front-proxy VM (revisit only as a mailbox *reader*)
- NATS / SQS / Kafka as the ledger
- Postgres as the accept point
- EventBus persistence (in-memory pub/sub; not a mailbox)
- Guest-visible maildir mount in v1
- Anything blocked on memory freeze/thaw (`mjolnir-3y6`) — orthogonal;
  it preserves RAM across sleep, it does not make 200 durable
- Visibility timeouts / competing-consumer leases until two workers
  steal from one pile

Defer until a real symptom: group-commit fsync (throughput), placement
index (second host), competing-consumer table (PUSH/PULL).

## Lineage

- Early MTAs (qmail/postfix): fsync spool, 250, retry, bounce. One
  file per message.
- [`../event-queue.md`](../event-queue.md) — email is the
  stress-tested event queue.
- [`../everything-is-a-channel.md`](../everything-is-a-channel.md) —
  named send as the universal primitive.
- Orleans virtual actors; Cloudflare Durable Objects (200 after
  storage commit); Kleppmann: at-least-once + idempotent consumer.

---

See also: [`../vm-messaging.md`](../vm-messaging.md) (what ships),
[`../actor-persistence.md`](../actor-persistence.md) (activation),
[`../decisions/0002-buzz-local-client-fabric.md`](../decisions/0002-buzz-local-client-fabric.md)
(OTP mailboxes are the queue; Admit is the facade).
