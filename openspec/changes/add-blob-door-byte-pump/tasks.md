# Tasks — add-blob-door-byte-pump

- [x] Disk cache module: incoming/objects, promote after accept, LRU, startup sweep
- [x] Stream PUT: pump body to incoming, incremental Blake3, 413/507, no `Bytes` extract
- [x] Stream GET/HEAD: cache hit from file; miss tees B2 and fills cache
- [x] CanonicalStore `put_path` + `get_stream`; B2 multipart above 64 MiB
- [x] Re-PUT is HeadObject no-op (no canonical GET to re-hash)
- [x] systemd `ReadWritePaths`; install migrates legacy `@blobs` off btrfs_root (stale wording; R4 is the remaining enforcement)
- [x] Tests: round-trip, mismatch leaves no object, re-PUT no extra version, 413, cache fill on GET miss
- [x] Docs: runbook, host-sidecars, crate README (64 MiB RAM cap is gone)

## Owed by architecture advise (2026-09-20)

- [ ] R1: Validate GET/HEAD hashes before cache/store access; regress encoded absolute/parent traversal, incoming-file reads, invalid hashes, and `.obao` path variants. See `reviews/2026-09-20-advise.md`.
- [ ] R2: Coordinate concurrent cache admission/publication/eviction and accounting; verify real disk usage for distinct/same-key PUT and GET-fill races, and preserve B2 fallback when eviction wins a cache-open race.
- [ ] R3: Discard GET fills on local flush/sync failure; fault-inject late local completion failure and prove no partial object is published and the next GET uses B2.
- [ ] R4: Enforce resolved production cache placement outside `btrfs_root`, including unsafe fallback and alias/`..` cases; align accepted custom paths with systemd write access and reconcile the stale `@blobs` install task.
- [ ] Fresh advise after preparation (send-back 2026-09-20; contract now names R1–R4)
