# add-blob-store

> **ACTIVE BUILD**

Activated from `nod-blob-arch` (Taskmaster intend, 2026-08-17).
Amended after advise send-back the same day.

**Rigor:** architecture

## Why

Taskmaster needs to store large blobs. The host sketch still said
backup and sync are later. Treating a guest disk (or a MinIO box we
had not contrasted) as the object would make the first VM the
architecture. The store has to be decided as layers: address,
canonical copy, working set / transmit.

## What

- ADR 0003 (amended): three layers. Address is recrypt
  `blob/b3/{base58}`. Canonical copy is **B2, written directly**.
  v1 door is ours (REST, other RPC, or Mjolnir messages) — callers
  do not speak S3. v2 working set / transmit is **iroh-blobs** on
  Mjolnir and Lightning Mesh nodes, draining to the same B2 keys.
- Accepted ⇒ HeadObject/GET on B2 succeeded. No ILM, no async
  replicate. **We are not doing MinIO** — not as the provider, not
  as a later cache.
- Hash-refuse and re-PUT no-op live on the put path.
- Encryption modes named (personal + PRE-share, or Guild-Key). Not
  implemented here. Store is untrusted for confidentiality; E2E Iroh
  is transmit.
- Capability `blob-store` (ADDED). Materialized by fold.
- Point Taskmaster’s sketch at this change after advise accept.

## Impact

- Capabilities: ADDED `blob-store` (materialized by fold)
- ADRs: 0003 (this change). Taskmaster `docs/ARCHITECTURE.md`
  amended in place after advise accept
- Living specs: bazaar `taskmaster` unchanged (ADR-006)

## User journey & surfaces

No new UI because this change decides the store. Put/get reach our
door and a hash column in the host DB. `add-blob-api` is the first
implement node. `add-blob-client` is the first Taskmaster surface.

- **Working (after implement nodes)** — the door process dies;
  every previously accepted hash still GETs from B2.
- **Working** — Taskmaster’s SQLite row names a Blake3 hash, not a
  path on the app VM.
- **Empty** — `openspec/specs/blob-store/` does not exist yet.
  Correct: fold creates it.
- **Failed** — a later change stores blob bytes in SQLite, treats a
  guest snapshot as the backup, or reports accepted before B2 has
  the object.
- **Off** — Duke parks the mesh. The ADR is amended in place with
  the reason, not deleted.

## Out of scope

- Implementing the door — `add-blob-api`
- Taskmaster put/get client — `add-blob-client`
- iroh-blobs working set / transmit — `add-iroh-blobs`
- Personal / Guild encryption and PRE — `add-encrypt-blobs`
- IdentiKey login, OIDC, managed-sign — their own nodes
- `mjolnir-qwp` for *other* VM classes
- MinIO — not at all (not a landing, not a later cache)
- Naming B2, MinIO, Iroh, or SvelteKit in bazaar `openspec/specs/`
