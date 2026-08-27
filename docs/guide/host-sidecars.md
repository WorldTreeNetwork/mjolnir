# Host sidecars — services every VM can reach

A Mjolnir guest is a real Linux machine on a TAP network. The host
runs a few **sidecars** on a reserved address that every guest can
ARP: `:host_api_ip`, default **`10.200.0.1`** (dummy interface
`dummy-mjolnir`, not loopback — TAP `/32` guests cannot hit
`127.0.0.1` on the host).

That is the affordance: **universal host services**, not a container
you had to compose next to the VM. Spawn a VM, read the locator,
talk HTTP or Postgres. Credentials for B2 and the BEAM's Unix-socket
catalog never enter the guest.

## How a guest finds them

On every boot the host injects `/etc/mjolnir/vm.json`:

```json
{
  "vm_id": "…",
  "api_url": "http://10.200.0.1:4000",
  "blob_door_url": "http://10.200.0.1:7222"
}
```

```bash
jq . /etc/mjolnir/vm.json
```

Guest TCP to `10.200.0.1` is **INPUT** on the TAP path, not FORWARD.
If a URL is right and the connection still black-holes, the UFW/nft
rule for that port is missing.

## Catalog

| Sidecar | Address | Who gets it | Locator |
|---|---|---|---|
| **Blob door** (content-addressed object store) | `http://10.200.0.1:7222` | Every VM | `blob_door_url` in `vm.json` |
| **Orchestrator API** | `http://10.200.0.1:4000` | Every VM (auth required except host loopback) | `api_url` in `vm.json` |
| **Postgres** (declared tenant DBs) | `10.200.0.1:5432` (scram) | App VMs with a provisioned tenant | `DATABASE_URL` in deploy secrets — **not** in `vm.json` |
| **Redis** (sessions / cache / queues) | `10.200.0.1:6379` (AUTH) | App VMs with a provisioned secret | `REDIS_URL` in deploy secrets — **not** in `vm.json` |

Not sidecars: MinIO (rejected — not v1, not a later cache), B2 itself
(only the door holds those keys), the public gateway (Iroh/HTTPS in, not
overlay). Appliances that are not Mjolnir guests (Edgebox, a Pi) should
still speak this layout (`blob/b3/`) rather than introducing MinIO;
`recrypt-server` sits in front for identity-gated put/get/share.

Names (2026-08-26): this sidecar is **Blob Door** in code and in the Edgebox
OSS insert. The business for the CAS layer is **Aeroblobs**
([aeroblobs.dev](https://aeroblobs.dev)). Recrypt is still the process in
front, not a rename of either.

---

## Blob door

Content-addressed blobs. Address is **Blake3 of the bytes, base58**.
Canonical copy is Backblaze B2. The guest speaks HTTP; it never
holds B2 keys. Not MinIO.

```bash
url=$(jq -r .blob_door_url /etc/mjolnir/vm.json)
# $hash = base58(blake3(file bytes))
curl -sS -X PUT --data-binary @file \
  -H 'content-type: application/octet-stream' \
  "$url/storage/blob/b3/$hash"     # 201 created, 200 already there
curl -sS "$url/storage/blob/b3/$hash" -o out
```

Routes: `PUT/GET/HEAD /storage/blob/b3/{hash}` and optional `.obao`.
Mismatch → 400. Same bytes again → 200, no extra B2 version. PUT cap
64 MiB. Do not send GiB through `deliver_message`.

Operator / deploy / Sites cutover: [blob-door runbook](../runbooks/blob-door.md).
Living spec: [`blob-store`](../../openspec/specs/blob-store/spec.md).
ADR: [`0003`](../decisions/0003-blob-store-mesh.md).

---

## Postgres (opt-in)

The OTP Postgres process is the host catalog **and**, for declared
tenants, a hotel: `CREATE DATABASE` per app, TCP on the same overlay
IP. A random spawn does **not** get a database. Provision with
`mix mjolnir.pg.tenant ensure`, then `mj deploy` reads `DATABASE_URL`
from the secrets file.

Runbook: [host-postgres-tenants](../runbooks/host-postgres-tenants.md).
App path: [Deploying a Web App](deploying-an-app.md).
ADR: [`0005`](../decisions/0005-host-sidecar-tenant-hotel.md).

---

## Redis (opt-in)

systemd `mjolnir-redis` on the overlay IP, not an OTP Port — `just
deploy` must not bounce sessions with the BEAM. AOF `everysec`. One
password, db 0 (not a hotel). A random spawn does **not** get
`REDIS_URL`. Provision with `mix mjolnir.redis.ensure --slug …`.

```bash
redis-cli -u "$REDIS_URL" PING
```

Runbook: [host-redis](../runbooks/host-redis.md).
ADR: [`0007`](../decisions/0007-host-sidecar-redis.md).

---

## Orchestrator API

`api_url` is how in-guest helpers (snapshot trigger, etc.) call back
to Mjolnir. Guests are not on `127.0.0.1`, so they do not get the
localhost auth bypass — they need a token like any other API client.

---

## Adding another sidecar

Bind it on `:host_api_ip` only (never `0.0.0.0`, never the public
NIC). Allow INPUT from `10.192.0.0/10` to that port. Put the locator
in `vm.json` (or a managed secret) — not credentials for the backing
store. Ride `just deploy` / `scripts/deploy.sh`; do not add a just
verb per sidecar.
