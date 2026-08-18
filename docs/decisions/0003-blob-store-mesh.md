# ADR 0003 — Content-addressed blob mesh (MinIO working set, B2 canonical)

**Status:** Proposed — awaiting advise
**Date:** 2026-08-17
**Change:** [`add-blob-store`](../../openspec/changes/add-blob-store/proposal.md)
**Living spec:** none yet (capability `blob-store` materializes at fold)
**Implement:** `add-minio-mesh` → `add-blob-client`. Encryption: `add-encrypt-blobs`.
**First consumer:** Taskmaster

Full argument: [`openspec/changes/add-blob-store/design.md`](../../openspec/changes/add-blob-store/design.md).

## One screen

1. **A provider is a Mjolnir guest running MinIO.** It is a working set,
   not a disk we backup.
2. **B2 is the canonical copy** of every accepted object, via MinIO’s
   S3-compatible remote. Accepted ⇒ on B2.
3. **Address is Blake3** of the stored bytes. Layout is recrypt’s:
   `blob/b3/{base58}`. Consume `recrypt-storage`. No third API.
4. **De-dupe is identity of stored bytes.** Encrypted objects do not
   plaintext-dedup (fresh random DEM). Do not add convergent encryption.
5. **Encryption sits above the store:** personal key then PRE-share, or
   Guild-Key. Store is untrusted for confidentiality.
6. **No FS-snapshot backup** for this VM class (`mjolnir-qwp` stays for
   other guests). Image snapshots are not the blob archive.
7. **Taskmaster SQLite holds hashes**, not bytes. Ready stays derived.
   One app VM, one SQLite file is unchanged.

## Built vs remaining

Built: nothing. This ADR is the shape.

Remaining: advise, then `add-minio-mesh`, then `add-blob-client`.
Do not spawn MinIO from this ADR.
