# ADR 0003 — Content-addressed blob mesh (B2 canonical, Iroh later)

**Status:** Accepted (advise accept-with-nits 2026-08-17)
**Date:** 2026-08-17
**Change:** [`add-blob-store`](../../openspec/changes/archive/2026-08-17-add-blob-store/proposal.md) (folded 2026-08-17 with `add-blob-api` and `add-blob-client`)
**Living spec:** [`openspec/specs/blob-store/spec.md`](../../openspec/specs/blob-store/spec.md)
**Remaining (activated):** [`add-blob-door-overlay`](../../openspec/changes/add-blob-door-overlay/proposal.md) — bind `:host_api_ip:7222`, inject `blob_door_url`, guest PUT/GET, Sites URL cutover. Later, not opened: `add-iroh-blobs` (working-set / transmit), `add-encrypt-blobs`. **Not MinIO.**
**First consumer:** Taskmaster. Guests use the same HTTP door on the overlay.

Full argument: [`openspec/changes/archive/2026-08-17-add-blob-store/design.md`](../../openspec/changes/archive/2026-08-17-add-blob-store/design.md).
Advise send-back: [`reviews/2026-08-17-advise.md`](../../openspec/changes/archive/2026-08-17-add-blob-store/reviews/2026-08-17-advise.md).
Re-advise: [`reviews/2026-08-17-readvise.md`](../../openspec/changes/archive/2026-08-17-add-blob-store/reviews/2026-08-17-readvise.md).

## One screen

1. **Three layers.** Address / layout; canonical durability; working
   set + transmit. A provider is anything that speaks the keys.
2. **v1: recrypt layout straight onto B2.** Accepted ⇒ HeadObject/GET
   on B2. Our door (REST, RPC, or Mjolnir messages). Callers do not
   speak S3. **No MinIO** — not in the middle, not later as a cache.
3. **Address is Blake3** of the stored bytes. Layout is recrypt’s:
   `blob/b3/{base58}`. Consume `recrypt-storage`. No third hash space.
4. **De-dupe is identity of stored bytes.** Encrypted objects do not
   plaintext-dedup. Do not add convergent encryption.
5. **Encryption sits above the store.** E2E Iroh is transmit, not
   store confidentiality.
6. **v2: iroh-blobs** as working-set / transmit on Mjolnir **and**
   Lightning Mesh nodes. Drain to the same B2 keys. Not the archive.
7. **No FS-snapshot backup** of a cache guest as the blob archive.
   v1 needs no such guest.
8. **Taskmaster SQLite holds hashes**, not bytes. Ready stays derived.

## Built vs remaining

Built (living spec): recrypt `blob/b3/` keys, B2 as canonical copy,
HTTP door crate (`mjolnir-blob-door`), Taskmaster `POST/GET /blob`
with hashes in SQLite. No MinIO.

Activated, not yet live (`add-blob-door-overlay`, beads `mjolnir-u8v7`):
door unit on the host bound to `:host_api_ip:7222` (`10.200.0.1`,
same dummy as tenant Postgres), INPUT from the TAP subnet, vsock
inject of `blob_door_url` into `/etc/mjolnir/vm.json`, Sites Recrypt
adapter pointed at this door. Operator path:
[`docs/runbooks/blob-door.md`](../runbooks/blob-door.md).

Remaining later: `add-iroh-blobs` on Mjolnir and Lightning Mesh;
encryption (`add-encrypt-blobs`). Do not treat iroh-blobs as the
copy that counts.
