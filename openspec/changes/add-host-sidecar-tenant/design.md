# Design — host sidecar as a tenant hotel

Canonical ADR index: [`docs/decisions/0004-host-sidecar-tenant-hotel.md`](../../../docs/decisions/0004-host-sidecar-tenant-hotel.md).
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

## Decision 2 — overlay TCP, not a socket mount, not the public NIC

Guests already reach the host as `10.255.255.1` (Forgejo runner URL, `systemd/forgejo-runner.service`). Tenant Postgres listens on **that same host overlay address, port 5432**.

- `listen_addresses` becomes that overlay IP, not `''`, not `*`, not `45.76.77.97`.
- `--auth-host=reject` is replaced with scram-sha-256 **for TCP**.
- Unix socket + peer + `--auth-local=peer` stays for the BEAM.
- Host firewall / bind must not publish 5432 on the public NIC. A probe from the internet to `45.76.77.97:5432` fails.

A virtiofs mount of the Unix socket was rejected: it is exactly the `extra_mounts` path the old spec named, it shares peer-auth identity with the BEAM, and it makes every such guest an ident-mapped OS user. Overlay TCP with a dedicated password is the smaller hole.

Unprovisioned guests: no secret, no `pg_hba` match that lets them in. Even if they can SYN `10.255.255.1:5432`, auth fails. Default spawn does not inject the secret.

## Decision 3 — tenant role is a hotel guest, not `mjolnir_sites`

`mjolnir_sites` must not gain DDL. Medusa migrations need CREATE/ALTER on *their* database.

Each tenant gets:

- `CREATE DATABASE "<name>" OWNER "<name>"`
- `CREATE ROLE "<name>" LOGIN PASSWORD …`
- CONNECT + full DDL/DML on that database only
- `REVOKE CONNECT ON DATABASE mjolnir` (never granted)
- No membership in `mjolnir_admin`

Password lives in host-escrowed managed secrets (`/var/lib/mjolnir/<app>-secrets.json` / SecretStore), injected at **Runtime.start**, never at Builder.build. Rotation = rewrite the secret, redeploy the app VM. Postgres `ALTER ROLE` is the source of truth for the password; the secret file must match.

## Decision 4 — backup is part of the hotel, not a follow-up wish

Sites indexes can be rebuilt from disk. A shop catalog cannot. This change owes:

- `pg_dump` of each tenant database on a timer (reuse `forgejo-backup.timer` shape or a new unit)
- Restore drill documented: drop/create database, `pg_restore`, point `DATABASE_URL` at it
- Dump files off the BTRFS VM volume (same discipline as secrets: not in `@snapshots`)

Without this, cutover-safe is a lie — a host disk loss wipes the shop.

## Decision 5 — in-flight `add-buzz-local-runtime` must not re-forbid this

That PENDING change still ADDs: “Stateful production workloads SHALL run real Postgres inside their own VM, not on the host sidecar.” After ADR 0004 is accepted, that sentence is wrong for **declared tenants**. Buzz relays and scratch still belong in-guest (PGlite on `@base/dev`, real PG in a relay VM). Handoff: amend `add-buzz-local-runtime` when this advise accepts. Do not fold the amendment into this change’s living delta until that PENDING file is edited.

## What we are not deciding

- Redis. Medusa’s `REDIS_URL` is unwired. Not this process.
- Putting uploads on Postgres. Files are a later volume/R2 question.
- Multi-host replication. One host, one postgres Port.
- Making every `mj deploy` app a tenant. Declaration is explicit.

## Tradeoff (the one we are taking)

We couple Hypersigil’s shop database to Mjolnir’s host postgres fate (upgrades, disk, the BEAM that supervises the Port). Isolation is `CREATE DATABASE` + bind address + password, not a hardware VM boundary. The gain is one supervised data plane, cutover-safe app VMs, and no second postgres to operate. The cost is that a sidecar outage or a bad `postgres.conf` overwrite takes the shop down with Sites. Backup and the public-NIC bind check are the mitigations we actually owe.
