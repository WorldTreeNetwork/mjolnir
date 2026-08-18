# ADR 0003 — Content-addressed blob mesh (B2 canonical, Iroh later)

**Status:** Proposed — send-back amend 2026-08-17, awaiting re-advise
**Date:** 2026-08-17
**Change:** [`add-blob-store`](../../openspec/changes/add-blob-store/proposal.md)
**Living spec:** none yet (capability `blob-store` materializes at fold)
**Implement:** `add-blob-api` → `add-blob-client`. Mesh: `add-iroh-blobs`.
  Encryption: `add-encrypt-blobs`. Not `add-minio-mesh`.
**First consumer:** Taskmaster

Full argument: [`openspec/changes/add-blob-store/design.md`](../../openspec/changes/add-blob-store/design.md).
Advise send-back: [`reviews/2026-08-17-advise.md`](../../openspec/changes/add-blob-store/reviews/2026-08-17-advise.md).

## One screen

1. **Three layers.** Address / layout; canonical durability; working
   set + transmit. A provider is anything that speaks the keys. Not
   “a MinIO guest.”
2. **v1: recrypt layout straight onto B2.** Accepted ⇒ HeadObject/GET
   on B2. Our door (REST, RPC, or Mjolnir messages). Callers do not
   speak S3. No MinIO in the middle.
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

Built: nothing. This ADR is the shape.

Remaining: re-advise, then `add-blob-api`. Do not spawn MinIO.
Do not treat iroh-blobs as the copy that counts.
