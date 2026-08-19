# Blob door (guest overlay)

Content-addressed blobs. Living spec
[`blob-store`](../../openspec/specs/blob-store/spec.md). ADR
[`0003`](../decisions/0003-blob-store-mesh.md). In-flight:
[`add-blob-door-overlay`](../../openspec/changes/add-blob-door-overlay/proposal.md).

The door is a **host sidecar**, not a VM. Canonical copy is Backblaze
B2. Callers (Taskmaster, Sites, guests) speak HTTP. They never hold
B2 keys. **Not MinIO.**

## Addresses

| Who | URL |
|---|---|
| TAP guest | `http://10.200.0.1:7222` (`:host_api_ip`, same dummy as tenant Postgres) |
| Host process | same — `10.200.0.1` is on `dummy-mjolnir` |
| Tests | `BLOB_DOOR_BACKEND=memory`, loopback |

Listen **only** on `10.200.0.1:7222`. Never `0.0.0.0`. Guest TCP to
the dummy is **INPUT**, not FORWARD — UFW must allow
`10.192.0.0/10` → `10.200.0.1:7222` (same shape as port 5432).

Routes:

```
PUT/GET/HEAD /storage/blob/b3/{hash}
PUT/GET      /storage/blob/b3/{hash}.obao
GET          /health
```

`{hash}` is base58 Blake3 of the stored bytes. Door refuses a
mismatch. Re-PUT of the same bytes is a no-op (no extra B2 version).
Ack only after HeadObject/GET on B2. v1 RAM cap 64 MiB.

## From a VM

After inject, `/etc/mjolnir/vm.json` has `blob_door_url` next to
`api_url`. No `B2_*` in the guest.

```bash
url=$(jq -r .blob_door_url /etc/mjolnir/vm.json)
# hash = base58(blake3(bytes))
curl -sS -X PUT --data-binary @file \
  -H 'content-type: application/octet-stream' \
  "$url/storage/blob/b3/$hash"
curl -sS "$url/storage/blob/b3/$hash" -o out
```

`deliver_message` is not the large-blob path (16 MiB cap).

## Install (does not restart Elixir)

```bash
# on the Mjolnir host, after rsync
cd /opt/mjolnir/native
cargo build -p mjolnir-blob-door --release
install -m 0755 target/release/mjolnir-blob-door /opt/mjolnir/bin/mjolnir-blob-door
install -m 0644 ../systemd/mjolnir-blob-door.service /etc/systemd/system/
# copy systemd/blob-door.env.example → /etc/mjolnir/blob-door.env
# fill B2_BUCKET / B2_KEY_ID / B2_APPLICATION_KEY (read/write, not delete)
# enable bucket versioning out of band
systemctl daemon-reload
systemctl enable --now mjolnir-blob-door
curl -sS http://10.200.0.1:7222/health
```

Do **not** restart `mjolnir.service` for a door change. Keys stay in
`/etc/mjolnir/blob-door.env`. Do not source that file into Taskmaster
or a guest.

## Sites

`Mjolnir.Sites.Storage.Recrypt` already speaks these routes. Point
`MJOLNIR_RECRYPT_STORAGE_URL=http://10.200.0.1:7222` and set
`:sites_storage_backend` to the Recrypt adapter. Default remains
local BTRFS until that cutover (`mjolnir-u8v7.4`). Do not send chunks
through recrypt-server `POST /files`.
