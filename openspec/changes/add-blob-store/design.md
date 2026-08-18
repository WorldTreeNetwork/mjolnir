# Design — content-addressed blob mesh

Canonical ADR index: [`docs/decisions/0003-blob-store-mesh.md`](../../../docs/decisions/0003-blob-store-mesh.md).
This file is the full argument. The index exists so `docs/decisions/`
stays browsable.

**Status:** Proposed — send-back amend 2026-08-17. Awaiting re-advise.
**Change:** `add-blob-store`
**First consumer:** Taskmaster (`~/work/Taskmaster/taskmaster-web`)
**Implement after accept:** `add-blob-api` (v1: recrypt layout on B2 +
our door) → `add-blob-client`. Mesh transmit: `add-iroh-blobs`.
Encryption: `add-encrypt-blobs`. **We are not doing MinIO** — not
v1, not a later cache, no `add-minio-mesh`.

Amended after advise 2026-08-17 (`reviews/2026-08-17-advise.md`).

## Problem

Four questions were still open after intend:

1. Where do large Taskmaster objects live, if not in the one SQLite file?
2. Is durability a BTRFS snapshot of a guest, or an object store that
   outlives any guest?
3. Do we grow a Taskmaster-only blob API, or consume recrypt’s?
4. What does “de-duped” mean once guild/hive bytes are encrypted?

Advise added a fifth: the first word of “provider” must not be a
product. Guessing MinIO in a spawn recipe makes the first box the
architecture. This amend splits the layers.

## Three layers (do not fuse)

| Layer | Job | v1 | Later |
|---|---|---|---|
| Address / layout | Hash is identity | recrypt `blob/b3/{base58}` + optional `.obao` | same keys, always |
| Canonical durability | Outlive any process | **B2, written directly** in that layout | still B2 |
| Working set + transmit | Serve recent bytes, NAT-traverse | none required | **iroh-blobs** on Mjolnir *and* Lightning Mesh nodes |

A **provider** is anything that can put/get those keys and register in
`ProviderIndex`. It is not “a MinIO guest.”

## Decision 1 — v1 is recrypt layout straight onto B2

**Backblaze B2 holds the canonical copy of every accepted object.**
The key is recrypt’s. The writer is our put path. There is no MinIO
in the middle, no ILM, no async replicate, no guest disk that we
pretend is the archive.

Accepted means the put path has observed the object on B2
(`HeadObject` or a GET of the same key) **before** it returns the
hash. ILM transition and bucket replication are not an accept-path.

Sites already planned this: `S3Storage` pointed at a B2 endpoint is
the same constructor as MinIO, different URL
(`docs/plans/initiatives/identikey-sites.md`). Recrypt already speaks
the layout (`recrypt-storage` `S3Storage`, keys in `src/s3.rs`).
Sites’ rclone of `@sites` stays the durability path for the *Sites
tree*. It is not this mesh: rclone is async, so it cannot be the
accept ack, and mixing GC/authz with site chunks is a later mess.

B2 versioning is **on** for this bucket. Blob keys are immutable
(re-PUT of the same hash is a no-op). Versioning is the safety net
if a mutable pointer or a mistaken overwrite ever appears. The
service principal that can `DeleteObject` is not the Taskmaster
principal.

Rejected as durability:

- **`mjolnir-qwp` / `btrfs send` → B2.** Filesystem generation, not
  “give me hash H.”
- **MinIO, at all.** Extra VM in front of an S3 API B2 already has.
  Does not buy the durability SHALL. Not v1. Not a later cache.
  Not the definition of a provider. We are not doing it.
- **iroh-blobs as the archive.** Transfer protocol + local store.
  No B2 sink. Last peer offline = data gone. That is the failure
  Decision 1 exists to kill.
- **LUKS volume as the object store.** Store is untrusted for
  confidentiality (Decision 5).

No storage-provider VM is required for v1. If a later node adds an
iroh-blobs `FsStore` working-set guest, that guest is **not**
enrolled in filesystem-snapshot backup (`mjolnir-qwp`). Image
snapshots for faster spawn are not the blob archive. Do not add a
MinIO guest instead.

## Decision 1b — Our door, not S3 as the client contract

v1 puts a service we own in front of B2. Callers do not speak B2
and do not need an S3 SDK. The door can be REST, another RPC, or
**Mjolnir messages** (`deliver_message` / vsock / Iroh ALPNs the
fabric already has). Same put path behind every face: verify hash,
write recrypt keys to B2, ack only after B2 has the object.

That is why S3-compatibility is not a reason to run MinIO. Agents
write the door. The scarce thing is the layout and the ack, not an
object-store OS.

Hash-refuse and re-PUT-as-no-op live on **this put path**
(`BlobStorage` impl or the sidecar). Raw S3 to B2 will accept any
bytes at any key; we never hand callers that socket. Recrypt’s
`put` already hashes; `put_with_outboard` today does not
(`recrypt-storage/src/s3.rs`) — the first implementer closes that
or wraps it.

`ProviderIndex` (`hash → [locator]`) exists from day one so a
second provider does not rename objects. v1 locators are the B2
(or door) URL. Later locators may be an iroh node-id + ticket.
Grammar is named in `add-blob-api`; this ADR only forbids a
parallel hash space.

## Decision 2 — Address is the hash. Layout is recrypt’s.

```
blob/b3/{base58(hash)}
blob/b3/{base58(hash)}.obao    # bao outboard; omitted ≤ 16 KiB
```

Blake3 of the **stored** bytes (ciphertext, when encrypted). This
is `recrypt-storage` (`BlobStorage`). Taskmaster does not grow a
third path scheme.

Recrypt chose `bao-tree` over embedding `iroh-blobs` so the
32-byte root stays bit-identical without taking iroh’s QUIC stack
(`docs/plans/2026-04-06-bao-streaming-and-storage-simplification.md`
§2.1). Sibling suffix is `.obao` here. iroh-blobs on disk uses
`.obao4`. Address bits match; the suffix is pinned when
`add-iroh-blobs` drains to B2. Do not fork the hash.

Do not hash through `Mjolnir.Sites.Crypto.blake3_hash/1` — that
seam is still a SHA-256 stub.

## Decision 3 — What a Taskmaster blob is

A blob is any host object that is **not** the work graph.

| Lives in SQLite (app VM) | Lives in the blob mesh |
|---|---|
| node, edge, assignment, session | evidence attachments |
| derived-ready is never stored | large agent artifacts |
| look / earned cookies | uploads, logs, screenshots, tarballs |

SQLite holds a **hash** (and maybe size, content-type, encryption
mode). It does not hold the bytes. Ready stays derived from edges.

The mesh is not Taskmaster-specific. First writer is Taskmaster so
the path is real. Guild/hive and Lightning Mesh nodes are later
consumers of the same hashes.

“Large” means bigger than a SQLite page or a JSON column. B2
accepts multipart. The door must stream; a first client may
buffer if that is called out. Recrypt’s `Vec<u8>` put is a client
limit, not a store limit.

## Decision 4 — De-dupe is identity of stored bytes

Recrypt’s hybrid encrypt uses fresh random XChaCha20 material.
**Plaintext dedup does not happen** for encrypted objects. Recrypt
already recorded this.

What does dedup: re-PUT of the same stored bytes; public objects
whose plaintext *is* the stored bytes; any later deterministic
encoding we explicitly choose. Do not add convergent encryption.

## Decision 5 — Encryption sits above the store

The store is **untrusted for confidentiality, trusted for
availability**. B2 (and any later iroh-blobs peer or local cache)
sees bytes and hashes. They do not see keys.

E2E Iroh QUIC hides bytes from relays and the ISP. It does **not**
hide bytes from the peer that stores them. Transmit confidentiality
is not store confidentiality.

Two modes, same chunk layer (Sites already uses this split):

1. **Personal, then PRE-share.** Encrypt to the user’s key. Share
   by recrypting the wrapped key (KEM). Bulk ciphertext unmoved.
2. **Guild-Key.** Encrypt to a guild key. Revocation is a
   guild-key problem, not a rewrite of the blob.

Public objects skip both. `add-encrypt-blobs` implements the modes.
This change forbids treating B2, bucket ACLs, LUKS, or Iroh
tickets as the confidentiality boundary, and forbids a third mode
invented in Taskmaster.

User-scoped authz waits on IdentiKey. v1 may use a Mjolnir
managed-secrets service principal on the door, not on B2 exposed
to Taskmaster.

## Decision 6 — One process, one SQLite file still holds

Taskmaster’s app VM stays one process, one SQLite file. The blob
door is a sibling (process or guest), not a second writer on that
file. libsql-onto-LUKS and write pools stay later.

Bazaar living specs do not name B2, MinIO, Iroh, SvelteKit, or SQLite.

## Decision 7 — Graduate to iroh-blobs as working-set / transmit

v2 of the *mesh*, not a replacement for B2.

Iroh in Mjolnir and Lightning Mesh today is **transport**: guest
shell / tcp-fwd / secret-inject ALPNs; mesh TUN + gossip. Neither
tree depends on `iroh-blobs`. Tickets are node addresses, not blob
capabilities. Relays assist hole-punch and **can** forward
ciphertext if a session never goes direct; they cannot decrypt
QUIC. LAN mesh is relay-free. That cost is already paid.

`add-iroh-blobs` adds the blobs ALPN and a local `FsStore` (or
equivalent) on:

- Mjolnir storage / app guests that should serve the working set
- **Lightning Mesh nodes** (the overlay already has Iroh identity
  and a path to every peer)

Those nodes register in `ProviderIndex` as locators for hashes
they hold. They **drain** accepted objects to B2 in recrypt
layout (or refuse to ack until the door has). Losing every
iroh-blobs peer is an availability blip, not data loss.

Verified streaming, range GET, resume, multi-source fetch are why
this layer exists. Recrypt’s decrypt path already wants
“iroh-blobs-style range protocol.” Do not take the `iroh-blobs`
crate as the durability backend (recrypt already rejected that
coupling).

Pin a production-quality iroh-blobs version when that node starts
(n0’s latest has been flagged not-prod). Decide `.obao` vs
`.obao4` on the drain. Taskmaster’s browser path stays HTTP to
our door; agents and mesh nodes may fetch over Iroh.

## Contrast (the table advise owed)

| Criterion | MinIO guest + B2 remote | iroh-blobs as archive | **v1: B2-direct + our door** | v2: iroh-blobs working set + B2 drain |
|---|---|---|---|---|
| Address | recrypt keys native | Blake3-32; must export to recrypt keys | recrypt keys native | same hashes; drain writes recrypt keys |
| Client contract | S3 | blobs ALPN + ticket | **our** REST / RPC / Mjolnir message | Iroh for mesh; door still for TS/browser |
| Transport | TLS to MinIO/B2 | Iroh QUIC E2E (relays already paid) | TLS to our door, then TLS to B2 | Iroh between mesh nodes |
| Durability | unproven sync (ILM/replicate ≠ ack) | local disk + peers; **no B2** | **PUT is the canonical copy** | B2 still the copy that counts |
| Existing code | `S3Storage` | no crate dep, no ALPN | `S3Storage` at a B2 endpoint | endpoints/relays paid; blobs unpaid |
| Existing fabric | none | transport paid; store unpaid | none required | Mjolnir + Lightning Mesh |
| Why pick it | cache that speaks the layout | mesh-native fetch | no extra VM; S3 is not the client API | E2E verified transfer; same hashes |

v1 is the third column. v2 is the fourth. MinIO is rejected, not
deferred. iroh-blobs as the *archive* is rejected.

## Consequences

- Losing any guest or mesh node is an availability blip, not data loss.
- A hash that is not on B2 is not accepted.
- Snapshotting a cache guest to “back up the blobs” is a bug.
- Callers never hold B2 keys.
- Taskmaster cannot answer “what can I start” from blob storage.
- The first VM (if any) is not the architecture.

## Proposed Taskmaster sketch amendment (apply after advise accept)

In `~/work/Taskmaster/taskmaster-web/docs/ARCHITECTURE.md`:

- Add a decided row: objects too large for the graph live in the
  blob mesh; SQLite stores the hash. Landing: `add-blob-store`.
  Implement: `add-blob-api`, `add-blob-client`. Mesh transmit later:
  `add-iroh-blobs` (Mjolnir + Lightning Mesh).
- Retract “backup is later” as if it covered blobs. Multi-instance
  *SQLite* stays later.
- Open item: IdentiKey login still a hop; user-scoped blob authz
  waits on it.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Bytes in SQLite | Large blobs, no mesh, backup is the DB file |
| New Taskmaster key scheme (`/taskmaster/{uuid}`) | Third layout beside recrypt |
| BTRFS snapshot → B2 of a store guest | Durability tied to one filesystem generation |
| Encrypt everything at LUKS on a guest | Store is untrusted; B2 still needed; no hash mesh |
| MinIO (v1, cache, or “provider”) | Extra VM in front of B2; we are not doing it |
| iroh-blobs as the archive | No independent copy; last peer offline loses data |
| recrypt-server as the only door | PRE proxy is a later node; our door is ours |
| Sites rclone as the accept-path | Async; cannot be the B2 ack |

## Open (do not block this ADR)

- Exact faces on the door (which REST routes, which Mjolnir message
  types) — `add-blob-api`.
- `ProviderIndex` process and locator grammar — `add-blob-api`.
- ML-DSA parameter set for signing manifests (65 vs 87) — protocol
  node.
- iroh-blobs crate pin and `.obao` vs `.obao4` — `add-iroh-blobs`.
- Relay policy for bulk Iroh transfer — `add-iroh-blobs` (default
  can match Lightning Mesh: n0 Staging, `--relay` hatch, LAN off).
