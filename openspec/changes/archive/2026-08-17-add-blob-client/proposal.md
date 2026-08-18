# add-blob-client

> **ACTIVE BUILD**

Activated from chat (2026-08-17). Depends on `add-blob-api`.

**Rigor:** change

## Why

ADR 0003 says Taskmaster SQLite holds hashes, not bytes, and callers
never speak B2. The door exists (`mjolnir-blob-door`). This change
is the first host client.

## What

- Capability `blob-store` (ADDED: Taskmaster talks to the door).
- Server-side client: Blake3 + base58, PUT/GET/HEAD
  `/storage/blob/b3/{hash}` on `BLOB_DOOR_URL`.
- Persist hash, size, content-type in SQLite. Never persist bytes.
  Never read `B2_*` env.
- HTTP surface: `POST /blob`, `GET /blob/{hash}`.

## Impact

- Capabilities: ADDED requirement on `blob-store`
- ADRs: none (implements 0003 Decision 3 / 1b)
- Code: `~/work/Taskmaster/taskmaster-web`

## User journey & surfaces

- **Working** — POST a body to `/blob`; response names a hash;
  GET `/blob/{hash}` returns the same bytes from the door; the
  `blob` row has no body column.
- **Empty** — `BLOB_DOOR_URL` unset: put/get fail closed (503).
- **Failed** — a change that stores bytes in SQLite or injects
  B2 keys into this app.
- **Off** — park; door still stands.

## Out of scope

- Door process — `add-blob-api` (landed)
- Upload UI — not this change
- Encryption — `add-encrypt-blobs`
- IdentiKey authz on `/blob` — A0
- iroh-blobs — `add-iroh-blobs`
- MinIO
