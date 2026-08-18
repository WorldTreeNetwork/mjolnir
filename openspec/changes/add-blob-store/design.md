# Design — content-addressed blob mesh

Canonical ADR index: [`docs/decisions/0003-blob-store-mesh.md`](../../../docs/decisions/0003-blob-store-mesh.md).
This file is the full argument. The index exists so `docs/decisions/`
stays browsable.

**Status:** Proposed — awaiting advise (activated 2026-08-17, `nod-blob-arch`).
**Change:** `add-blob-store`
**First consumer:** Taskmaster (`~/work/Taskmaster/taskmaster-web`)
**Implement after accept:** `add-minio-mesh` → `add-blob-client`. Encryption is `add-encrypt-blobs`.

## Problem

Four questions were still open after intend:

1. Where do large Taskmaster objects live, if not in the one SQLite file?
2. Is durability a BTRFS snapshot of a guest, or an object store that
   outlives any guest?
3. Do we grow a Taskmaster-only blob API, or consume recrypt’s?
4. What does “de-duped” mean once guild/hive bytes are encrypted?

Guessing any of these in a spawn recipe makes the first MinIO box the
architecture.

## Decision 1 — A provider is a cache. B2 is the copy that counts.

A **storage provider** is a Mjolnir guest running MinIO. It is not a
disk we backup. It is a working set: recently used and recently written
objects, served over S3.

**Backblaze B2 holds the canonical copy of every accepted object.**
The guest may be destroyed, snapshotted for *image* cutover, or
replaced. None of those events may be how we keep a blob.

Mechanism (preferred): MinIO’s S3-compatible remote to B2 — replicate
or ILM-transition so that an accepted PUT is on B2 before we tell the
caller the hash is durable. Local eviction is allowed. Local-only
objects are not accepted.

Rejected for this VM class:

- **`mjolnir-qwp` / `btrfs send` → B2.** That backups a filesystem
  generation. It cannot answer “give me hash H from any provider.”
  Keep it for app guests and other disks.
- **Sites rclone of `@sites`.** Right shape for the host Sites tree
  (content-addressed, append-only copy). Wrong place: the MinIO guest
  is not that tree, and we do not want a second copy pipeline beside
  MinIO→B2.
- **LUKS volume as the object store.** Tier-3 is for secrets the host
  must not read. Blob *bytes* are either public or already encrypted
  above the store; the store is untrusted for confidentiality. Paying
  LUKS here loses BTRFS features and does not make B2 canonical.

Turn **off** filesystem-snapshot backup for this VM class. Snapshot
the *image* if we need a faster spawn; do not treat those snapshots as
the blob backup.

## Decision 2 — Address is the hash. Layout is recrypt’s.

Objects are keyed by the **Blake3** hash of the bytes we store
(ciphertext, when encrypted). Wire key:

```
blob/b3/{base58(hash)}
blob/b3/{base58(hash)}.obao    # bao outboard; omitted ≤ 16 KiB
```

This is `recrypt-storage`’s S3 layout (`BlobStorage`, `S3Storage`).
Taskmaster **consumes that crate** (or a thin TS client that speaks
the same keys). It does not grow a third path scheme.

A second provider is a second URL for the same hash. Recrypt’s
`ProviderIndex` (`hash → [provider_url]`) is the registry. First
landing is one MinIO VM plus B2; the index still exists so a second
provider does not rename anything.

iroh-blobs uses the same 32-byte Blake3 root. We do not speak iroh
in this change. We do not pick a different hash.

## Decision 3 — What a Taskmaster blob is

A blob is any host object that is **not** the work graph.

| Lives in SQLite (app VM) | Lives in the blob mesh |
|---|---|
| node, edge, assignment, session | evidence attachments |
| derived-ready is never stored | large agent artifacts |
| look / earned cookies | uploads, logs, screenshots, tarballs |

SQLite holds a **hash** (and maybe size, content-type, encryption
mode). It does not hold the bytes. Ready stays derived from edges.

The mesh is not Taskmaster-specific. Guild/hive hosts are later
consumers of the same providers. First writer is Taskmaster so the
path is real.

“Large” means: bigger than we will put in a SQLite page or a JSON
column. The store path (MinIO + B2) accepts multipart / streaming.
The first client (`add-blob-client`) may still buffer if that is
called out; the store must not.

## Decision 4 — De-dupe is identity of stored bytes

Recrypt’s hybrid encrypt uses fresh random XChaCha20 material. Two
encrypts of the same plaintext are different ciphertexts. **Plaintext
dedup does not happen** for encrypted objects. Recrypt already
recorded this; do not cite it as a benefit of those objects.

What does dedup:

- Re-PUT of the **same stored bytes** (same hash → no-op).
- Unencrypted / public objects whose plaintext *is* the stored bytes.
- Any later deterministic encoding we explicitly choose.

Do not add convergent encryption to force plaintext dedup. That is a
new cryptosystem.

## Decision 5 — Encryption sits above the store

The store is **untrusted for confidentiality, trusted for
availability**. MinIO and B2 see bytes and hashes. They do not see
keys.

Two modes, same chunk layer (Sites already uses this split):

1. **Personal, then PRE-share.** Encrypt to the user’s key. Share by
   recrypting the wrapped key (KEM). Bulk ciphertext (DEM) unmoved.
2. **Guild-Key.** Encrypt to a guild key. Members who hold that key
   decrypt. Revocation is a guild-key problem, not a rewrite of the
   blob.

Public objects skip both. `add-encrypt-blobs` implements the modes.
This change only forbids treating MinIO/B2 as the confidentiality
boundary, and forbids a third mode invented in Taskmaster.

C2 managed keys and C3/C4 self-custody are how those keys exist.
They are other nodes. The store does not wait on login to be
*shaped*; the first put/get may use a Mjolnir managed-secrets
service principal. User-scoped authz waits on IdentiKey.

## Decision 6 — One process, one SQLite file still holds

Taskmaster’s app VM stays one process, one SQLite file. The blob
mesh is a **sibling guest**, not a second writer on that file.
libsql-onto-LUKS and write pools stay later, and stay off this
change.

Bazaar living specs do not name MinIO, B2, SvelteKit, or SQLite.

## Consequences

- Losing the MinIO VM is an availability blip, not data loss.
- A hash that is not on B2 is not accepted.
- Snapshotting the MinIO guest to “back up the blobs” is a bug.
- Taskmaster cannot answer “what can I start” from blob storage.
- Recrypt-storage’s current `Vec<u8>` put is a client limit, not a
  store limit. Streaming is `add-blob-client` / an upstream recrypt
  slice, not a reason to fork the layout.

## Proposed Taskmaster sketch amendment (apply after advise accept)

In `~/work/Taskmaster/taskmaster-web/docs/ARCHITECTURE.md`:

- Add a decided row: objects too large for the graph live in the
  blob mesh; SQLite stores the hash. Landing: `add-blob-store`
  (this change). Implement: `add-minio-mesh`, `add-blob-client`.
- Remove “Backup / sync / multi-instance are later” as if it still
  covered blobs. Multi-instance *SQLite* stays later.
- Open item: IdentiKey login still a hop; user-scoped blob authz
  waits on it.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Bytes in SQLite | Large blobs, no mesh, backup is the DB file |
| New Taskmaster S3 client with ad-hoc keys | Third layout beside recrypt |
| BTRFS snapshot → B2 of the MinIO guest | Durability tied to one filesystem generation |
| Encrypt everything at LUKS on the guest | Host-visible working set lost; B2 still needed; no hash mesh |
| Wait for iroh-blobs | Compatible addresses; not a first provider |
| recrypt-server as the only door | Extra hop; PRE proxy is a later node |

## Open (do not block this ADR)

- Immediate replicate vs ILM transition delay — implement node picks
  the MinIO knob; the invariant is “accepted ⇒ on B2.”
- ML-DSA parameter set for *signing* manifests (65 vs 87) — protocol
  node, not the store.
- Whether B2 versioning is on. Prefer on, so a mistaken overwrite of
  a mutable pointer cannot silently destroy history. Blob keys
  themselves are immutable.
