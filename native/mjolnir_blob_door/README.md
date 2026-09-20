# mjolnir-blob-door

HTTP door for ADR 0003. Recrypt keys (`blob/b3/{base58}`) on Backblaze B2.
Callers never hold B2 credentials. **Not MinIO.**

Production bind is the guest overlay, not loopback:

`BLOB_DOOR_BIND=10.200.0.1:7222` plus `BLOB_DOOR_ALLOW_NONLOCAL=1`
(`:host_api_ip`, same dummy as tenant Postgres). TAP guests cannot
reach `127.0.0.1` on the host. Never `0.0.0.0`. Operator path:
[`docs/runbooks/blob-door.md`](../../docs/runbooks/blob-door.md).
Activated change: `add-blob-door-overlay`.

```
PUT/GET/HEAD /storage/blob/b3/{hash}
PUT/GET      /storage/blob/b3/{hash}.obao
GET          /health
```

Accepted = HeadObject/GET on B2 succeeded after a hash-checked write.
Re-PUT of the same bytes is a no-op (no extra version). No DELETE.

PUT/GET stream through a host-disk cache (`BLOB_DOOR_CACHE_DIR`,
default `/var/lib/mjolnir/btrfs/@blobs`, 64 GiB budget). Accept is
still HeadObject on B2. `BLOB_DOOR_MAX_BYTES` defaults to 1 TiB;
ENOSPC is 507. The cache is not the archive.

Build (Linux host for production; macOS is fine for `cargo test`):

```
cd native && cargo test -p mjolnir-blob-door
cargo build -p mjolnir-blob-door --release
```

Install `target/release/mjolnir-blob-door` as `/opt/mjolnir/bin/mjolnir-blob-door`
and `systemd/mjolnir-blob-door.service` with `systemd/blob-door.env.example`.
Enable B2 bucket versioning before first write. Do not restart Elixir
to install this unit.

`BLOB_DOOR_BACKEND=memory` is for tests only (loopback). Guests use
`http://10.200.0.1:7222` after `blob_door_url` is injected into
`/etc/mjolnir/vm.json`.
