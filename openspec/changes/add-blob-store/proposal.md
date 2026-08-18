# add-blob-store

> **ACTIVE BUILD**

Activated from `nod-blob-arch` (Taskmaster intend, 2026-08-17).

**Rigor:** architecture

## Why

Taskmaster needs to store large blobs. The host sketch still says backup
and sync are later, and the only durable path Mjolnir already runs is
BTRFS snapshots (or rclone of a host Sites tree) into B2. That path
treats the guest disk as the object, so a content-addressed mesh cannot
grow, a second provider cannot serve the same hash, and encrypted
guild/hive bytes would sit on a snapshot we keep taking. The store has
to be decided before anyone spawns a MinIO box, or the first VM becomes
the architecture.

## What

- ADR 0003: a loose mesh of storage-provider VMs. Each provider is
  MinIO on a Mjolnir guest. B2, via MinIO’s S3-compatible remote, is
  the canonical copy of every accepted object. The guest is a working
  set, not the durability story. Content-addressed, de-duped at
  ciphertext identity. Consume `recrypt-storage`; do not grow a third
  blob API.
- Turn **off** filesystem-snapshot backup (`mjolnir-qwp`, Sites rclone
  of this guest’s root) for this VM class.
- Name the encryption modes (personal + PRE-share, or Guild-Key) so
  later `add-encrypt-blobs` has a shape. Do not implement them here.
- Capability `blob-store` (ADDED). Materialized by fold, not by this
  proposal existing.
- Point Taskmaster’s sketch at this change and retract “backup is later”
  as if it were still the decision. Stack names stay out of the bazaar
  living specs.

## Impact

- Capabilities: ADDED `blob-store` (materialized by fold)
- ADRs: 0003 (this change). Taskmaster `docs/ARCHITECTURE.md` amended
  in place after advise accept — it is a sketch, not a kernel SHALL
- Living specs: bazaar `taskmaster` unchanged (ADR-006: stack is not
  kernel truth)

## User journey & surfaces

No new UI because this change decides the store. Put/get already reach
the S3 API on the provider VM and a hash column in the host DB.
`add-blob-client` is the first Taskmaster surface.

- **Working (after implement nodes)** — an operator loses the MinIO
  guest; every previously accepted hash still GETs from B2 (or a
  replacement provider that registered the same hash).
- **Working** — Taskmaster’s SQLite row names a Blake3 hash, not a
  path on the app VM.
- **Empty** — `openspec/specs/blob-store/` does not exist yet. Correct:
  fold creates it.
- **Failed** — a later change stores blob bytes in the Taskmaster
  SQLite file, or treats a BTRFS snapshot of the MinIO guest as the
  backup. This ADR names both a defect.
- **Off** — Duke parks the mesh. The ADR is amended in place with the
  reason, not deleted.

## Out of scope

- Spawning the first MinIO VM — `add-minio-mesh` (`nod-minio-mesh`)
- Taskmaster put/get client — `add-blob-client`
- Personal / Guild encryption and PRE — `add-encrypt-blobs`
- IdentiKey login, OIDC, managed-sign — their own nodes
- `mjolnir-qwp` for *other* VM classes (app guests, Sites host tree)
- iroh-blobs as a provider (addresses stay compatible; not this landing)
- `recrypt-server` HTTP as a required hop for v1 put/get
- Naming MinIO, B2, or SvelteKit in bazaar `openspec/specs/`
