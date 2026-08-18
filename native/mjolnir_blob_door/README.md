# mjolnir-blob-door

HTTP door for ADR 0003. Recrypt keys (`blob/b3/{base58}`) on Backblaze B2.
Callers never hold B2 credentials. **Not MinIO.**

```
PUT/GET/HEAD /storage/blob/b3/{hash}
PUT/GET      /storage/blob/b3/{hash}.obao
GET          /health
```

Accepted = HeadObject/GET on B2 succeeded after a hash-checked write.
Re-PUT of the same bytes is a no-op (no extra version). No DELETE.

v1 holds the body in RAM up to `BLOB_DOOR_MAX_BYTES` (default 64 MiB).
Larger objects need a later streaming slice.

Build (Linux host for production; macOS is fine for `cargo test`):

```
cd native && cargo test -p mjolnir-blob-door
cargo build -p mjolnir-blob-door --release
```

Install `target/release/mjolnir-blob-door` as `/opt/mjolnir/bin/mjolnir-blob-door`
and `systemd/mjolnir-blob-door.service` with `systemd/blob-door.env.example`.
Enable B2 bucket versioning before first write.

`BLOB_DOOR_BACKEND=memory` is for tests only.
