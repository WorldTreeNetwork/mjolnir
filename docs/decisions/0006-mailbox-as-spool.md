# ADR 0006 — Mailbox as a per-actor filesystem spool

**Status:** Accepted (advise accept-with-nits 2026-08-22)
**Date:** 2026-08-21
**Change:** [`add-mailbox-durable-accept`](../../openspec/changes/archive/2026-08-22-add-mailbox-durable-accept/proposal.md) (folded 2026-08-22)
**Living spec:** [`openspec/specs/vm-mailbox/spec.md`](../../openspec/specs/vm-mailbox/spec.md)
**Epic:** `mjolnir-5le4`
**Philosophy:** [`../philosophy/mailbox-as-spool.md`](../philosophy/mailbox-as-spool.md)

Full argument:
[`openspec/changes/archive/2026-08-22-add-mailbox-durable-accept/design.md`](../../openspec/changes/archive/2026-08-22-add-mailbox-durable-accept/design.md).

## One screen

1. **200 is durable accept.** Fsync `@mail/<vm_id>/<message_id>.json`
   (tmp + file fsync + exclusive link + **directory** fsync) before 200.
   Producer may forget.
2. **Filename is identity.** Producer `id`; retries are duplicates.
   Omitted id → host generates, retry-safety off.
3. **One queue.** VM state gates *when* to deliver, never *whether
   the message exists*. Delete `retry_deliver_message`, the
   `:restoring` reject, and the boot GenServer list.
4. **Two ACKs.** Vsock ACK = RAM hint, never deletes. Application
   ACK tombstones.
5. **Unacked mail is the wake.** `signal_done` race is a file, then
   restore. No activate API.
6. **Admit:** never-message → fail POST, no file. Don’t-thaw → 200
   queued, no restore. A proxy VM, if ever, **reads** the spool.
7. **FS ledger, not Postgres, not a broker.** Placement (multi-host)
   is a derived directory; the spool travels with the actor.
8. **Give-up / bounce** after TTL or max attempts. Compose 0MQ
   *above* named send. PUSH/PULL claim state is later.

## Built vs remaining

Built (living spec): `Mjolnir.Mailbox` spool, API `id` +
`queued|duplicate`, guest peek/`POST /ack`, vsock ACK is a hint,
startup sweep, bounce on kill, give-up TTL.

Remaining (not this capability): multi-host placement directory,
competing-consumer claim, tenant-policy VM as a mailbox **reader**
(`mjolnir-5le4.4`). Guest agent on a live body needs
`just deploy --agent`.
