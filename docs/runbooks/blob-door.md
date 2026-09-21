# Blob door (guest overlay)

Content-addressed blobs. Guest how-to and sidecar catalog:
[`guide/host-sidecars.md`](../guide/host-sidecars.md). Living spec
[`blob-store`](../../openspec/specs/blob-store/spec.md). ADR
[`0003`](../decisions/0003-blob-store-mesh.md). Folded overlay change:
[`add-blob-door-overlay`](../../openspec/changes/archive/2026-08-19-add-blob-door-overlay/proposal.md).

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
Ack only after HeadObject/GET on B2. The door is a **write-through
caching proxy**: it pumps the body onto host SSD
(`/var/lib/mjolnir/blobs`, 64 GiB budget) and uploads from
that file. That path is **outside** `btrfs_root` — same reason
escrow is not on the data volume. A cache on BTRFS would be
CoW-pinned by every snapshot and fill the disk monotonically.
Accept is still B2, not the local file. Per-object ceiling 1 TiB
(`BLOB_DOOR_MAX_BYTES`); disk full is 507. Cache is not the
archive — wiping it does not lose accepted objects.

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

## Install

Rides `just deploy` (`scripts/deploy.sh`). After rsync it builds the
crate, installs the unit, and restarts **only** `mjolnir-blob-door` —
not Elixir. First-time env is minted by `scripts/install-blob-door.sh`
if `/etc/mjolnir/blob-door.env` is missing.

```bash
just deploy
curl -sS http://10.200.0.1:7222/health   # from the host
```

Keys stay in `/etc/mjolnir/blob-door.env`. Do not source that file into
Taskmaster or a guest.

## Sites

`Mjolnir.Sites.Storage.Recrypt` speaks these routes. Content hashes and
IdentiKey fingerprints are real Blake3 (`mjolnir-b3`). Cutover:

```
MJOLNIR_RECRYPT_STORAGE_URL=http://10.200.0.1:7222
MJOLNIR_BLAKE3_BIN=/opt/mjolnir/bin/mjolnir-b3
```

in `/etc/mjolnir/env`, then restart Elixir (bounces VMs). Default
without that env is still local BTRFS. Do not send chunks through
recrypt-server `POST /files`. Already-published sites keep serving
from materialized plaintext until republished.
