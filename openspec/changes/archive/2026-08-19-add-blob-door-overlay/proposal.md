# add-blob-door-overlay

> **ACTIVE BUILD**
>
> Folded 2026-08-19 → `openspec/specs/blob-store/spec.md`.
> Sites Recrypt cutover held as `mjolnir-u8v7.4` (Blake3 stub).

Activated from chat 2026-08-19 (intend: guest HTTP to the host blob
door). Beads: `mjolnir-u8v7` and children `.1`–`.3` folded; `.4` open.

**Rigor:** change

Depends on folded ADR 0003 (`add-blob-store` / `add-blob-api` /
`add-blob-client`) and the live `:host_api_ip` dummy from
`add-host-sidecar-tenant`.

## Why

The door crate exists and Taskmaster can speak it, but the process is
not installed and it binds `127.0.0.1:7222`. TAP guests cannot reach
host loopback. The overlay address already assigned for tenant
Postgres (`10.200.0.1` on `dummy-mjolnir`) is the host-from-guest
path. A VM should PUT/GET `/storage/blob/b3/{hash}` there. No B2
keys in the guest. No MinIO.

## What

- Bind `mjolnir-blob-door` on `:host_api_ip:7222` (`10.200.0.1`),
  `BLOB_DOOR_ALLOW_NONLOCAL=1`. Never `0.0.0.0`, never the public
  NIC. Fail closed if the dummy address is missing.
- INPUT allow TAP subnet → that port (same trap as 5432: guest TCP
  to the dummy is INPUT, not FORWARD).
- Install the unit on the Mjolnir host. `just` recipe must not
  restart Elixir.
- Inject `blob_door_url` into `/etc/mjolnir/vm.json` via vsock
  `configure_identity` (next to `api_url`).
- Prove from a guest: PUT/GET, mismatch refuse, re-PUT no extra B2
  version; B2 still has the object after the door dies.
- Point `Mjolnir.Sites.Storage.Recrypt` at the door
  (`MJOLNIR_RECRYPT_STORAGE_URL`). Stop waiting on recrypt-server
  `/files`.
- Capability `blob-store` (ADDED requirements).

## Impact

- Capabilities: ADDED requirements on `blob-store`
- ADRs: none (0003 Decision 1b already allowed loopback or the
  private guest net)

## User journey & surfaces

Duke, from Ghostty / `mj connect` / `mj exec` inside a guest, and
from Sites publish on the host.

- **Working (after)** — guest `curl` PUT then GET
  `http://10.200.0.1:7222/storage/blob/b3/{h}`; `/etc/mjolnir/vm.json`
  names `blob_door_url`; no `B2_*` in the guest.
- **Empty** — door unit not installed; bind is still loopback;
  `vm.json` has only `api_url`.
- **Failed** — INPUT missing (black-hole with a valid URL); bind
  `0.0.0.0`; B2 keys in the guest; `deliver_message` used for GiB.
- **Off** — park; B2 objects already accepted stay. Loopback Taskmaster
  on the host can still use `http://10.200.0.1:7222` once the dummy
  is up.

No new UI because the outcome already reaches guest `curl` / `mj exec`
and Sites `Store.put_chunk`.

## Out of scope

- MinIO — rejected by ADR 0003
- iroh-blobs working set / transmit — `add-iroh-blobs`
- Personal / Guild encryption — `add-encrypt-blobs`
- Streaming above the door's 64 MiB RAM cap
- recrypt-server `/files` as a second door
- A third overlay IP besides `:host_api_ip`
