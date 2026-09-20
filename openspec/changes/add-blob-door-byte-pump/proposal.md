# add-blob-door-byte-pump

> **ACTIVE BUILD**
>
> Activated from chat 2026-09-19. The 64 MiB ceiling is a RAM
> buffer, not B2. Replace it with a disk-backed byte pump that
> caches locally and write-throughs to B2. Bead `mjolnir-ysi7`.

**Rigor:** architecture

Depends on folded `add-blob-store` / `add-blob-door-overlay`
(ADR 0003). Does not change overlay bind, keys, or accept proof.

## Why

The door extracts the whole PUT as `Bytes` and holds it in RAM.
`DEFAULT_MAX_BYTES` is 64 MiB so the host does not OOM. GET
collects B2 into a `Vec` too. That is a weak blob store.

The host already has a data SSD (`/var/lib/mjolnir/btrfs`, ~150 GiB
free). The door should be a **caching proxy**: pump bytes onto that
disk, hash while writing, upload from the file to B2, keep the file
as a working-set cache. Accept is still HeadObject on B2. Cache is
not the archive.

## What

- Stream PUT/GET. No full-object RAM buffer. Axum
  `DefaultBodyLimit::disable()`. Hash Blake3 incrementally.
- Host disk sink + LRU cache at `/var/lib/mjolnir/blobs`
  (**outside** `btrfs_root` — snapshots must not pin cache extents).
  Default cache budget **64 GiB**. Incoming files under
  `incoming/`, accepted objects under `objects/`.
- Write-through: 2xx accepted only after B2 HeadObject confirms,
  same as today. Local file is not the durability proof.
- Per-object ceiling **1 TiB** (`BLOB_DOOR_MAX_BYTES`), disk full
  → 507. Multipart upload to B2 above 64 MiB.
- GET: cache hit streams the file; miss tees B2 → client and
  fills the cache.
- systemd `ReadWritePaths` on the cache dir (`ProtectSystem=strict`).
- Capability `blob-store` (ADDED requirements).

## Impact

- Capabilities: ADDED on `blob-store`
- ADRs: none (0003 already said the door is not the archive)
- Host disk: 64 GiB working-set at `/var/lib/mjolnir/blobs` (not `btrfs_root`)

## User journey & surfaces

Duke, from a guest (`curl` / `mj exec`) or any HTTP client of
`blob_door_url`. Same routes.

- **Working (after)** — PUT of hundreds of MiB (and up to the
  disk) returns 201 after B2 confirms; GET of that hash is served
  from `/var/lib/mjolnir/blobs/objects/` without another
  B2 download; door restart still GET-misses from B2.
- **Empty** — cache dir missing or empty; first GET after a miss
  fills it.
- **Failed** — hash mismatch (400, incoming deleted); disk full
  (507); B2 down (502/503, incoming deleted, not accepted).
- **Off** — park; B2 objects already accepted stay. Cache can be
  wiped; it is not the archive.

No new UI because the outcome already reaches guest `curl` /
`mj exec` and Sites `Store.put_chunk`.

## Out of scope

- MinIO
- iroh-blobs
- Encryption
- Sites Elixir `Plug.Conn.read_body` 64 MiB and `mj` client
  `MAX_BODY` — those are a different hop. Direct door HTTP is the
  large-object path.
- recrypt-server `/files`
- Serving a cache-only object as accepted (violates ADR 0003)
- Write-back / ack-before-B2
