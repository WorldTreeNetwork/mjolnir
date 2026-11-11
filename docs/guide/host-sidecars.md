# Host sidecars — services every VM can reach

A Mjolnir guest is a real Linux machine on a TAP network. The host
runs a few **sidecars** on a reserved address that every guest can
ARP: `:host_api_ip`, default **`10.200.0.1`** (dummy interface
`dummy-mjolnir`, not loopback — TAP `/32` guests cannot hit
`127.0.0.1` on the host). `mjolnir-hotel-ip.service` assigns that
`/32` at boot (`scripts/ensure-host-api-addr.sh`). Sidecar installers
install and start that unit before they bind. If `dummy` cannot be
created, the assign fails and the address stays off `lo`.
`scripts/ensure-host-modules.sh` writes
`/etc/modules-load.d/mjolnir.conf` so the next boot loads kvm, tun,
vhost_vsock, and dummy for the installed kernel.
`mjolnir-nat.service` puts the guest masquerade back. It does not
start `nftables.service`: the packaged `nftables.conf` drops
forwarded traffic.

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
  "blob_door_url": "http://10.200.0.1:7222",
  "aie_url": "http://10.200.0.1:7422"
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
| **AIE compute** (NPU jobs by overlay RPC)¹ | `http://10.200.0.1:7422` | VMs holding an execute right on a signed offer | `aie_url` in `vm.json`; omitted when off |

¹ Built. Unit `mjolnir-aie` (user `mjolnir-aie`, not root) on dummy-mjolnir
`:7422`, INPUT, catalog design ids only. BEAM admit is
`/run/mjolnir/aie-admit.sock` (`0660` root:`mjolnir-aie`), not
`operator.sock`. Occupancy is IRON Lab `occupancy.lock`. The contract is
[ADR 0015](../decisions/0015-aie-compute-sidecar.md). HTTP execute shape
is `POST {aie_url}/v1/execute` (catalog design + bounded input). `aie_url` is omitted from the example above when
the unit is down or `/dev/accel/accel0` is missing.

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
Mismatch → 400. Same bytes again → 200, no extra B2 version. The
door streams to host SSD (`/var/lib/mjolnir/blobs`, outside
`btrfs_root`) and write-throughs to B2; 1 TiB safety rail, 64 GiB
cache budget. Do not send GiB through `deliver_message`.

Operator / deploy / Sites cutover: [blob-door runbook](../runbooks/blob-door.md).
Living spec: [`blob-store`](../../openspec/specs/blob-store/spec.md).
ADR: [`0003`](../decisions/0003-blob-store-mesh.md).

---

## Postgres (opt-in)

The OTP Postgres process is the host catalog **and**, for declared
tenants, a hotel: `CREATE DATABASE` per app, TCP on the same overlay
IP. A random spawn does **not** get a database. Provision with
`mix mjolnir.pg.tenant ensure`, which **merges** `DATABASE_URL` into the
deploy-secrets file. Extra keys (JWT, Stripe, SES) are `mj secrets set`
— same file, then `mj deploy`. `mj secrets ls <app>` lists names.

Runbook: [host-postgres-tenants](../runbooks/host-postgres-tenants.md).
App path: [Deploying a Web App](deploying-an-app.md).
ADR: [`0005`](../decisions/0005-host-sidecar-tenant-hotel.md).

---

## Redis (opt-in)

systemd `mjolnir-redis` on the overlay IP, not an OTP Port — `just
deploy` must not bounce sessions with the BEAM. AOF `everysec`. One
password, db 0 (not a hotel). A random spawn does **not** get
`REDIS_URL`. Provision with `mix mjolnir.redis.ensure --slug …`
(merges). Confirm with `mj secrets ls <app>`.

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

## AIE compute

NPU jobs over overlay HTTP. The guest never receives `/dev/accel`. The
sidecar opens `accel0` as `mjolnir-aie`, binds `10.200.0.1:7422`, and
calls BEAM enqueue/admission on `aie-admit.sock`. Occupancy is the same
flock `ironlab` uses (`$XDG_RUNTIME_DIR/ironlab/occupancy.lock`); the
XRT worker inherits that fd. Catalog design ids only — a guest xclbin
is refused. Install rides `just deploy` (`scripts/install-aie-sidecar.sh`).

```bash
jq -r .aie_url /etc/mjolnir/vm.json
# null / missing when the unit is off or there is no accel node
```

The offer principal is the allowlisted **VM being's IdentiKey**. The
`mjolnir-aie` OS account opens the device; it cannot grant capacity. Spawn
does not publish an offer or mint an execute token. `share` points at the
current signed leaf already published under that being's keyspace:

```bash
mj compute share OWNER_FP npu
# Offer owner grants a second VM holder (public key is base64 Ed25519):
mj compute share OWNER_FP npu --keypair-file being.json \
  --grant-to HOLDER_PUBLIC_KEY > grant.json
# Consumer uses its own key, never the offering VM's private key:
mj compute run OWNER_FP npu vector-add --keypair-file consumer.json \
  --grant-file grant.json --input input.bin --state-file job.json
# Recover after a CLI restart or a lost HTTP reply:
mj compute run OWNER_FP npu vector-add --keypair-file consumer.json \
  --input input.bin --state-file job.json --resume
```

The owner can run with its own key and omit `--grant-file`. For a guild
use `--member-public-key BASE64_MEMBER_KEY` to select the current
member-signed delegation; membership is rechecked after the occupancy
lock. The keypair file uses `ed25519_public` and `ed25519_secret` (base64
32-byte keys, as with `mj sites`). Locators come from
`/etc/mjolnir/vm.json`; outside a guest, supply `--api` and `--aie-url`.
An absent `aie_url` refuses execution. Input is at most 1 MiB and reaches
the catalog worker on stdin. Guests receive neither `/dev/accel` nor
`/dev/dri`; a guest path or xclbin is not a catalog design.

`GET /api/aie/challenge` returns a single-use nonce and the host mint-root
holder fingerprint (lowercase hex), which is the audience. An overlay URL
alone is insufficient. `POST /api/aie/mint` accepts an owner-signed request
to grant a holder, or an existing holder's signed refresh. It mints a
holder-checked Biscuit with
`right("OWNER_FP/OFFER_ID/INCARNATION", "aie-execute")`. A third identity
without that grant receives 403. `Offer.mint/2` still only copies the
incarnation from the current verified leaf.

`POST {aie_url}/v1/execute` without `pending_id` verifies the execute
proof through `/api/aie/prepare`, enqueues through `aie-admit.sock` (which
consumes the nonce), and returns `pending_id` before starting any worker.
The client saves its proof and that id, then repeats the execute call with
`{"design_id":"vector-add","pending_id":"pnd_…","proof":{…}}`.
The proof includes base64 input, Biscuit, public key and signature, the
nonce, audience, resource, method `POST`, design and idempotency key.
The sidecar takes the occupancy lock, calls `/api/aie/check` to revalidate
that stored proof, current being/offer and guild, and admits through
`aie-admit.sock`. These AIE HTTP ceremonies verify their own proofs and
confer no operator scopes. `AIE_BEAM_ADDR` defaults to `10.200.0.1:4000`;
it is a host-controlled address, never supplied by the guest.

The signed message is `mjolnir/aie-execute/v1` plus NUL, followed by
uint32 big-endian length-prefixed fields in this order: Biscuit base64,
nonce, audience, method, resource, raw Blake3 of decoded input, design id,
idempotency key, holder public key (empty on execute), and member key
(empty for personal offers). Mint uses `mjolnir/aie-mint/v1` plus NUL,
method `MINT`, empty input/design, and the target holder public key.

While an attempt is live, the client repeats the exact same proof and
`pending_id`; enqueue time stays fixed. A lost reply does not mint or
consume another nonce. A short-lived completed result is status only and
never authorizes another load. After abandonment, cancellation, sidecar
or BEAM restart, or queue expiry, the old reference cannot load. The
client records a terminal failure; run again without `--resume` to obtain
a fresh nonce and enqueue a new job. A lost enqueue reply has not started
a worker and also requires a fresh nonce. Pending state files contain
capability material and are written atomically with mode 0600.

ADR: [`0015`](../decisions/0015-aie-compute-sidecar.md).

---

## Adding another sidecar

Bind it on `:host_api_ip` only (never `0.0.0.0`, never the public
NIC). Allow INPUT from `10.192.0.0/10` to that port. Put the locator
in `vm.json` (or a managed secret) — not credentials for the backing
store. Ride `just deploy` / `scripts/deploy.sh`; do not add a just
verb per sidecar.
