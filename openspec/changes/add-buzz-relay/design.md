# Design — B0 Buzz relay on Mjolnir

**Status:** Amended after 2026-09-10 send-back — awaiting re-advise.
**Change:** `add-buzz-relay`
**Bead:** `mjolnir-gti`
**Steer:** `steer.md` (domain = `buzz.identikey.me`)

## Problem

The free provider's only fully-working demo target is a relay we
operate. Block's hosted hive refuses NIP-OA provider-deployed
identities. We have the adapter repo, `@base/buzz-agent`, and the
gateway. We do not have a hive.

## Decision 1 — one VM, native units, data on the guest

One named guest `buzz-relay` runs four systemd units: `buzz-relay`
(+ `buzz-admin` on PATH), Postgres 17, Redis 7, MinIO. Block's
`deploy/compose/.env` contract is the env schema, not the runtime.
`DATABASE_URL` / `REDIS_URL` / `BUZZ_S3_ENDPOINT` point at
`127.0.0.1`. Membership ops are `buzz-admin` with that env (that is
all `run.sh add-member` wraps).

Not four VMs. Not host-postgres / host-redis. ADR 0002 / living
`buzz-local-client` already forbids putting the community event log
on the sidecar; ADR 0005's tenant hotel is for declared tenants
(hypersigil), not Buzz.

A snapshot of this VM includes Postgres, Redis AOF, MinIO, and the
git volume. `mj snapshot create` is crash-consistent (guest `sync` →
pause → btrfs snapshot → resume). That is the B0 backup. `mj freeze`
(memory snapshot) is not the backup verb.

**Tradeoff.** `mj deploy` cutover boots a *new* VM from a release
snapshot and stops the old one — empty hive. Treat `buzz-relay` as
**stateful**: spawn once, adopt into `Deploy.Registry` without
cutover, snapshot for backup, do not casual-cutover. Binary upgrades
are in-guest package/image refresh, then a snapshot.

## Decision 2 — gateway TLS, not nested Caddy

Block's `BUZZ_COMPOSE_TLS=true` overlay adds Caddy + host :80/:443.
The Mjolnir gateway already terminates HTTPS on 45.76.77.97 and
raw-TCP-proxies to the guest `:3000` (`Disposition::Local`). Nested
Caddy would fight SNI and ACME.

`RELAY_URL=wss://buzz.identikey.me` with no port. The relay binds
`:3000` inside the guest only; the gateway is the public listener.
Do not run Caddy in the guest.

WebSocket: the local disposition is a bidirectional TCP proxy, not
an HTTP router, so the `ws` upgrade is the guest's problem.

## Decision 3 — `buzz.identikey.me` is the community identity

`RELAY_URL` keys the hive (host, port, scheme, byte for byte).
Steer picked `buzz.identikey.me`. `docs/gateway-routing.md` §"How to
point a name" is **stale**: it claims `*.identikey.me` CNAMEs to
`vm.worldtree.network` and a wildcard Origin cert. Live DNS
(2026-09-10, after Duke updated the zone): `buzz.identikey.me` CNAME
`identikey.me` → A `45.76.77.97` (same as `auth.identikey.me`). The
Linode `74.207.254.179` apex is gone. Host certs are still HTTP-01
per host (`auth.identikey.me` only); worldtree ACME DNS-01 cannot
issue that zone. An explicit `buzz` A/CNAME (not via the apex) is
the better pin so the hive does not move if the apex does.

Required before liveness:

1. DNS: `buzz.identikey.me` A `45.76.77.97` (or CNAME
   `vm.worldtree.network`), same shape as `auth.identikey.me`.
2. Registry adopt (Decision 6) then `mj domain set buzz-relay
   buzz.identikey.me`.
3. `mj cert issue buzz.identikey.me` (HTTP-01) after DNS answers at
   the gateway on :80.

Set `RELAY_URL` **before** the relay process first starts. Changing
it later seeds an empty community. Mark the gateway-routing doc
aspirational or fix it in the same change so the next reader is not
misled.

## Decision 4 — NIP-OA on, closed membership, existing owner

Compose `.env.example` already has the policy we need:

```
BUZZ_REQUIRE_AUTH_TOKEN=true
BUZZ_REQUIRE_RELAY_MEMBERSHIP=true
BUZZ_ALLOW_NIP_OA_AUTH=true
```

Owner pubkey is the Desktop identity that already attests Fizz/Honey
on cgcoop:

`f3dbbf663cd541de2503a541bfbf9652075dd28cebc624d21ee9ab0d1c118c1d`

The member-identity workaround (claim a plain membership, drop
`BUZZ_AUTH_TAG`) stays undocumented on this hive and is not the
default join path. It costs `!shutdown`.

Relay signing key (`BUZZ_RELAY_PRIVATE_KEY`) is generated once,
never committed. Same paranoia as a TLS key, plus reputation.

`mj secrets` (deploy-secrets) is the **wrong surface**: living
`deploy-secrets` says a newly set key reaches the guest only on
redeploy, and redeploy is the cutover this hive forbids. Spawn the
VM with `secrets_mode: managed`, then `POST /api/vms/:id/secrets`
with the Block `.env` map. The agent renders `/run/mjolnir/secrets.env` as `export KEY='v'`
at `0640 root:agent`. systemd `EnvironmentFile=` ignores `export`
lines. Units copy `Deploy.Runtime.systemd_unit/5`:
`ExecStart=/bin/sh -lc 'exec …'` (profile.d sources the file),
`After=`/`WantedBy=mjolnir-secrets.target`, run as root or a user
in group `agent`. Do not start `buzz-relay.service` until secrets
are mounted.

## Decision 5 — native units, not Docker-in-guest

The guest kernel is `ch_defconfig` 6.12.8 with
`# CONFIG_NETFILTER is not set` and `# CONFIG_BRIDGE is not set`.
`scripts/build-kernel.sh` only adds virtio/PVH/dm-crypt. Live
guests have overlay/fuse/cgroup2/veth but no bridge, no iptables.
virtiofsd starts without `--xattr`, so overlay2 cannot write
`trusted.overlay.*`. No `@base/*` ships docker. Enabling compose
would be a host-wide kernel rebuild (every VM reboots) plus a
virtiofsd flag — that is a new runtime, not B0.

Host has `skopeo` (no docker/crane). Extract
`ghcr.io/block/buzz:main` on the host, copy `buzz-relay` /
`buzz-admin` into the guest. Postgres 17 from pgdg, Ubuntu redis,
MinIO single binary. 4096 MB.

## Decision 6 — Registry adopt, not `mj deploy`

`mj domain set`, `mj cert`, and `Policy.App` all `registry_get`.
Only `Deploy.Runtime.start` writes a row today, and that path
cutovers. `Deploy.Detector` is SvelteKit-only.

Add a cutover-free adopt: `PUT /api/apps/:app` (CLI `mj app adopt`)
that `Registry.put`s `{app_name, service_vm_id, port,
release_snapshot, owner_id}` for an **existing** running VM. It
MUST NOT spawn, stop, or replace a VM. `release_snapshot` is the
VM's current rootfs snapshot name (or a sentinel the route
generator already accepts). Redeploy of an adopted stateful app
is refused or requires an explicit force flag — the default is
leave it alone.

## What this does not decide

- How `buzz-backend-mjolnir` `deploy` creates agent VMs (still a stub).
- B1 egress as a signed export (`mjolnir-80q`).
- Whether a later `@base/buzz-relay` image bakes the four units.
