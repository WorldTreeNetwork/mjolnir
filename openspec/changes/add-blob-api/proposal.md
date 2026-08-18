# add-blob-api

> **PENDING**

**Rigor:** change

Depends on accepted ADR 0003 (`add-blob-store`).

## Why

ADR 0003 decided the store: recrypt keys on B2, our door, no MinIO.
The door is still design-only. If we implement without a change, fold
loses “callers never hold B2 keys,” and the first process becomes an
S3 SDK in Taskmaster. This change is that door.

## What

- Capability `blob-store` (ADDED requirements). Living spec still
  materializes when `add-blob-store` folds; this delta rides with it.
- First face is **HTTP**, same routes Sites already specified:
  `PUT/GET /storage/blob/b3/{hash}` and the `.obao` sibling.
- Door is a **process on an existing Linux box** (Mjolnir host
  sidecar, same pattern as the planned recrypt-storage sidecar). Not
  a new VM class. Not MinIO.
- Put path: hash-refuse, exists-then-skip, write B2, **HeadObject
  or GET on B2**, then ack. Wrap `put_with_outboard` (it does not
  hash-check today).
- Callers never see B2 credentials. DeleteObject principal is not
  the caller principal. B2 versioning is on.
- v1 `ProviderIndex` locator is the door URL (canonical copy is
  still B2). Grammar for iroh tickets is `add-iroh-blobs`.
- Blake3 is real Blake3, not `Mjolnir.Sites.Crypto.blake3_hash/1`.

## Impact

- Capabilities: ADDED requirements on `blob-store`
- ADRs: none (implements 0003 Decision 1b)
- We are not doing MinIO

## User journey & surfaces

No new UI because the surface is HTTP put/get on the door. Taskmaster
screens are `add-blob-client`.

- **Working (after act)** — Taskmaster (or `curl` on the host) PUTs
  bytes to `/storage/blob/b3/{h}`; the door returns accepted only
  after B2 has `{h}`; GET of `{h}` from the door returns the same
  bytes; killing the door does not lose `{h}`.
- **Empty** — no door process yet. PENDING.
- **Failed** — a client is given B2 keys, or accepted is returned
  after PUT 200 without HeadObject, or GiB go through
  `deliver_message`.
- **Off** — park this change; ADR 0003 still stands; no door ships.

## Out of scope

- Taskmaster client / hash column — `add-blob-client`
- iroh-blobs working set / transmit — `add-iroh-blobs`
- Encryption (personal + PRE, Guild-Key) — `add-encrypt-blobs`
- IdentiKey user-scoped authz — A0 / `add-identikey-login`
- Mjolnir-message and other RPC faces — later on the same put path
- Recrypt-server PRE / `/files` multisig — stays recrypt’s
- MinIO
- `mjolnir-qwp` as the archive
