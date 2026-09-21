# Design — blob door byte pump

Implements streaming + host-disk cache in front of ADR 0003's B2
canonical copy. Not a new ADR.

**Status:** ACTIVE BUILD
**Change:** `add-blob-door-byte-pump`
**Parent:** ADR 0003 (accepted). Overlay bind from `add-blob-door-overlay`.

## Pins

1. **Byte pump, not a RAM blob.** PUT streams the body to an
   `incoming/` file in 64 KiB–1 MiB HTTP chunks, Blake3-updating as
   it writes. GET streams a file or tees B2. Axum
   `DefaultBodyLimit::disable()`. Never `extract Bytes` for the
   object. Re-PUT does not GET the canonical object back to re-hash
   it — HeadObject size + the just-hashed body is enough.

2. **Write-through. Cache is not accept.** 2xx accepted still means
   HeadObject (or GET) on B2 succeeded. Incoming files are deleted
   on hash mismatch, B2 failure, or drop. GET never serves
   `incoming/`. A cache hit is allowed only for an object that was
   promoted after accept (or filled from a successful B2 GET). A
   GET fill that fails flush or sync is discarded, never published.
   If a cache path vanishes between lookup and open, fall back to
   B2; do not 404 an accepted object.

3. **Host SSD sink, outside `btrfs_root`.** Production path is
   `/var/lib/mjolnir/blobs` (ext4 OS disk, same reason escrow is
   not on the data volume). A cache on BTRFS is CoW-pinned by every
   VM / named snapshot; LRU cannot free those extents and the disk
   fills monotonically. Default cache budget 64 GiB
   (`BLOB_DOOR_CACHE_BYTES`). Objects larger than the budget are
   still accepted (B2) but not retained. LRU by explicit atime
   touch. `ProtectSystem=strict` needs `ReadWritePaths` on that
   dir. PrivateTmp is not the cache. Install **and process start**
   refuse a `BLOB_DOOR_CACHE_DIR` whose **resolved** path is under
   `btrfs_root` (symlink / `..` / unsafe fallback included) and
   migrate the legacy `@blobs` subvolume off the data disk.
   Concurrent promotions keep actual `objects/` bytes ≤ budget.

4. **Crazy-large ceiling, disk is the real cap.** Default
   `BLOB_DOOR_MAX_BYTES` is 1 TiB. ENOSPC → 507. Multipart to B2
   above 64 MiB, part size `max(16 MiB, ceil(len/10000))` so a TiB
   object stays under S3's 10k-part limit. Single PutObject stays
   under B2's 5 GiB single-PUT max.

5. **Same routes, same keys.** `PUT/GET/HEAD /storage/blob/b3/{hash}`
   and `.obao`. Callers do not change. No MinIO. No public bind.

6. **Identifiers are hashes, not paths.** `{hash}` is a 32-byte
   Blake3 in base58 (optional `.obao`) on PUT, GET, and HEAD,
   validated before any `objects.join`. Absolute paths, `..`, and
   path separators are 4xx. Send-back 2026-09-20 R1: GET/HEAD used
   to skip this check and would serve `/etc/passwd` or
   `incoming/`.

## Layout

```
/var/lib/mjolnir/blobs/          # NOT under btrfs_root
  incoming/<pid>-<seq>           # in-flight PUT or GET-fill
  objects/<base58>               # accepted (or B2-filled) payload
  objects/<base58>.obao
```

Sweep `incoming/` on start.

## Not this change

Sites/Plug 64 MiB, `mj` `MAX_BODY`, iroh-blobs, encryption, a
public gateway route, write-back.
