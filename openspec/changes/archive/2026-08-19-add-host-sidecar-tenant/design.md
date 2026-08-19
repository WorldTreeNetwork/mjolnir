# Design — host sidecar as a tenant hotel

Canonical ADR index: [`docs/decisions/0005-host-sidecar-tenant-hotel.md`](../../../docs/decisions/0005-host-sidecar-tenant-hotel.md).
This file is the full argument.

**Status:** Proposed — awaiting advise.
**Change:** `add-host-sidecar-tenant`
**First consumer:** Hypersigil Medusa (`add-mjolnir-manifest` in hypersigil-store-backend)
**Supersedes:** ADR 0002 item 7 only.

## Problem

`mj deploy` boots a fresh service VM and stops the previous one. Anything on that rootfs is gone. Medusa’s catalog is source of truth, not a derived index. Three shapes survived intend:

1. Host-mounted data dir into every cutover VM.
2. A second long-lived data VM.
3. Reopen the OTP Postgres sidecar as a tenant hotel.

Duke picked (3). The living spec and the code both refuse it today.

## What is true in code today

`Mjolnir.Postgres.Server` writes `listen_addresses = ''` and `initdb --auth-host=reject` (`lib/mjolnir/postgres/server.ex`). Bootstrap creates database `mjolnir` and LOGIN roles `mjolnir_admin` (DDL) and `mjolnir_sites` (CRUD, no DDL) (`lib/mjolnir/postgres/bootstrap.ex`). Connections are peer auth on a Unix socket under `/var/run/mjolnir`. Guests have no mount of that socket and no TCP listener.

Living spec `buzz-local-client` requirement “Host sidecar is control-plane only”: indexes as schemas in the host database; SHALL NOT hold a tenant app database or a Buzz event log; guests SHALL have no network path, including via `extra_mounts`.

That rule was written so Buzz relays and random guests cannot become a row in Mjolnir’s catalog. It was not written because OTP cannot run a second database. The process can. The policy forbade it.

## Decision 1 — one postgres, two classes of database

Keep a single OTP-managed `postgres` Port. Do not start a second cluster.

| Class | Database | Auth | DDL | Rebuildable |
|---|---|---|---|---|
| Control plane | `mjolnir` | Unix socket, peer, BEAM OS user | `mjolnir_admin` only | Yes (derived indexes) |
| Tenant | `CREATE DATABASE <ident>` | TCP on overlay + scram-sha-256 | tenant LOGIN role, on that database only | No — backup is owed |

A tenant is **declared** (first: `hypersigil`). It is not “any guest that asks.” Bootstrap of `mjolnir` does not create tenant databases. A `Mjolnir.Postgres.Tenants` API / host command does, idempotently.

Buzz community event logs stay off this process. That is the part of ADR 0002 item 7 that does not move.

## Decision 2 — reserved host-from-guest TCP, not a socket mount, not the public NIC

The tree already names one host-from-guest IP: `:host_api_ip` default `10.200.0.1` (`lib/mjolnir/vm.ex`, injected as the in-guest API URL). It is **not assigned today** (TAPs have no host IP; `allocate_ip/1` can still emit it). This change makes that one address real and exclusive.

- Host bootstrap (`scripts/bootstrap-host-ubuntu.sh` and the running host) assigns `10.200.0.1/32` on a dummy or `lo` interface **before** postgres starts.
- `Network.allocate_ip/1` refuses `10.200.0.1` (and must not emit it via the `o4 == 0 → 1` rewrite).
- Tenant Postgres `listen_addresses` is exactly that IP, port 5432. Not `''`, not `*`, not the default-route NIC.
- If the address is missing at postgres start, boot **fails**. Never fall back to `*` / `0.0.0.0`.
- TCP auth is scram-sha-256. Unix socket + peer + `--auth-local=peer` stays for the BEAM.
- `pg_hba` host lines (rewritten every boot with `postgresql.conf`) are per-database, overlay CIDR `10.200.0.0/10`, scram-sha-256 — not `0.0.0.0/0`. Unprovisioned guests get no match.
- 5432 is not listening on `0.0.0.0` or the default-route NIC.

Do not cite `FORGEJO_HOST_URL=http://10.255.255.1:3000` as a guest→host bind. That is a **host unit** env var. `10.255.255.1` sits in the guest pool (`.1` is a legal last octet) and is not reserved. Do not invent a third host-from-guest address.

A virtiofs mount of the Unix socket was rejected: it is exactly the `extra_mounts` path the old spec named, it shares peer-auth identity with the BEAM, and it makes every such guest an ident-mapped OS user. Overlay TCP with a dedicated password is the smaller hole.

Default spawn does not inject the tenant secret.

## Decision 3 — tenant role is a hotel guest, not `mjolnir_sites`

`mjolnir_sites` must not gain DDL. Medusa migrations need CREATE/ALTER on *their* database.

`Mjolnir.Postgres.Tenants.ensure/1` (identifier `^[a-z_][a-z0-9_]*$`) is idempotent and is **not** called from sidecar bootstrap (`:rest_for_one` must not create shop DBs on Mjolnir boot). Invocation is an operator command **and** a declared list (first entry: `hypersigil`, slug `hypersigil-api` to match `mj deploy --name`).

Each ensure:

- Generates a password if the role is new; `ALTER ROLE` if rotating.
- `CREATE DATABASE "<name>" OWNER "<name>"` (skip if present).
- `CREATE ROLE "<name>" LOGIN PASSWORD …` — **not** added to `pg_roles` config / `pg_ident.conf`. The BEAM must not peer-map into the shop.
- `REVOKE CONNECT ON DATABASE mjolnir FROM PUBLIC` then re-grant `mjolnir_admin` / `mjolnir_sites`.
- `REVOKE CONNECT ON DATABASE "<name>" FROM PUBLIC` then grant the owner. Same on every other tenant DB so LOGIN roles cannot walk the hotel.
- Writes `DATABASE_URL` into `/var/lib/mjolnir/deploy/secrets/<slug>.json` (the path `Deploy.Orchestrator.default_read_secrets/1` actually reads). Do not invent `/var/lib/mjolnir/<app>-secrets.json`.
- Injected at **Runtime.start**, never `Builder.build`. Rotation = `ALTER ROLE` + rewrite that JSON + redeploy the app VM.

`pg_hba.conf` (clobbered every start, `server.ex`) gains, for each tenant DB:

```
host <db> <role> 10.200.0.0/10 scram-sha-256
```

No `host all all`. Unix-socket peer lines for the BEAM stay as they are.

## Decision 4 — backup is part of the hotel, not a follow-up wish

Sites indexes can be rebuilt from disk. A shop catalog cannot. Postgres data already lives at `/var/lib/mjolnir/pg` (not a VM subvolume). “Off `@vms`” is therefore vacuous — a dump next to the data dir dies with the host disk.

This change owes two dumps:

1. **Disaster recovery (host timer).** Same shape as `systemd/forgejo-backup.service`: scheduled `pg_dump` of each tenant database to an **off-host** sink (Backblaze B2 or the existing backup bucket), not a local path on the postgres disk. Restore recreates role + database from that object, then rewrites `deploy/secrets/<slug>.json` if the password changed.
2. **Exit (Duke leaves).** `pg_dump` over the same tenant TCP `DATABASE_URL` from a guest or a laptop on the overlay. The catalog walks with him. Capture of convenience (managed host) is allowed; capture of the rows is not.

Cutover-safe does not need (1). Host-disk-safe and the exit test both do.

## Decision 5 — in-flight `add-buzz-local-runtime` is amended in this change

That PENDING change ADDed: “Stateful production workloads SHALL run real Postgres inside their own VM, not on the host sidecar.” Leaving it is two in-flight truths. This change **edits that sentence now**: declared host-postgres tenants MAY use the sidecar; Buzz relays and other undeclared production workloads still SHALL run Postgres inside their own VM. Scratch stays PGlite on `@base/dev`.

## What we are not deciding

- Redis. Medusa’s `REDIS_URL` is unwired. Not this process.
- Putting uploads on Postgres. Files are a later volume/R2 question.
- Multi-host replication. One host, one postgres Port.
- Making every `mj deploy` app a tenant. Declaration is explicit.

## Tradeoff (the one we are taking)

We couple Hypersigil’s shop database to Mjolnir’s host postgres fate (upgrades, disk, the BEAM that supervises the Port). Isolation is `CREATE DATABASE` + bind address + password, not a hardware VM boundary. The gain is one supervised data plane, cutover-safe app VMs, and no second postgres to operate. The cost is that a sidecar outage or a bad `postgres.conf` overwrite takes the shop down with Sites. Backup and the public-NIC bind check are the mitigations we actually owe.
