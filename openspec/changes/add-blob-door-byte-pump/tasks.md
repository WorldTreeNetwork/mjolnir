# Tasks — add-blob-door-byte-pump

- [x] Disk cache module: incoming/objects, promote after accept, LRU, startup sweep
- [x] Stream PUT: pump body to incoming, incremental Blake3, 413/507, no `Bytes` extract
- [x] Stream GET/HEAD: cache hit from file; miss tees B2 and fills cache
- [x] CanonicalStore `put_path` + `get_stream`; B2 multipart above 64 MiB
- [x] Re-PUT is HeadObject no-op (no canonical GET to re-hash)
- [x] systemd `ReadWritePaths`; install script creates `@blobs`, bumps env
- [x] Tests: round-trip, mismatch leaves no object, re-PUT no extra version, 413, cache fill on GET miss
- [x] Docs: runbook, host-sidecars, crate README (64 MiB RAM cap is gone)
