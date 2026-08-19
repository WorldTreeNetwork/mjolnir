# host-postgres

What is built. Folded from
[`add-host-sidecar-tenant`](../../changes/archive/2026-08-19-add-host-sidecar-tenant/proposal.md)
on 2026-08-19. ADR
[`0005`](../../../docs/decisions/0005-host-sidecar-tenant-hotel.md).

## Purpose

Declared tenant apps get `CREATE DATABASE` on the OTP sidecar.
Control-plane catalog `mjolnir` stays Unix-socket peer. Buzz event
logs stay off this process.

## Requirements

### Requirement: Declared tenant database

`Mjolnir.Postgres.Tenants.ensure/1` SHALL, for an identifier matching
`^[a-z_][a-z0-9_]*$`, idempotently create a `CREATE DATABASE` of that
name owned by a LOGIN role of the same name. That role SHALL have DDL
on its database and SHALL NOT be listed in `pg_ident.conf`. Control-plane
roles `mjolnir_admin` and `mjolnir_sites` SHALL NOT be reused as the
tenant role. Bootstrap of `mjolnir` SHALL NOT create tenant databases.

#### Scenario: First tenant hypersigil

- GIVEN the sidecar is up and tenant `hypersigil` is not present
- WHEN `Tenants.ensure("hypersigil", slug: "hypersigil-api")` runs
- THEN database `hypersigil` exists
- AND `deploy/secrets/hypersigil-api.json` contains `DATABASE_URL`

### Requirement: Overlay TCP only

When `:pg_tenant_listen_ip` is set, `listen_addresses` SHALL be that
address only (default `:host_api_ip` `10.200.0.1`). If the address is
not assigned, postgres start SHALL fail and SHALL NOT rewrite listen
to `*` or `0.0.0.0`. `Network.allocate_ip/1` SHALL NOT return the
reserved host-from-guest address. Unix-socket peer auth SHALL remain
the BEAM path to `mjolnir`. TCP auth SHALL be scram-sha-256.
`pg_hba` host lines SHALL be per-tenant-database, source
`10.200.0.0/10`.

#### Scenario: Bind IP missing fails closed

- GIVEN `:pg_tenant_listen_ip` is set and not assigned
- WHEN postgres starts
- THEN start fails
- AND `listen_addresses` is not rewritten to `*` or `0.0.0.0`

#### Scenario: allocate_ip skips the hotel bind

- GIVEN `:host_api_ip` is `10.200.0.1`
- WHEN `Network.allocate_ip/1` runs
- THEN the result is never `10.200.0.1`

### Requirement: Secrets stay out of snapshots

`Tenants.ensure/1` SHALL write `DATABASE_URL` to
`/var/lib/mjolnir/deploy/secrets/<slug>.json`. Tenant roles SHALL NOT
appear in `pg_ident.conf`.

#### Scenario: PUBLIC cannot walk the hotel

- GIVEN tenant `hypersigil`
- WHEN `Tenants.ensure` completes
- THEN `REVOKE CONNECT FROM PUBLIC` has been applied on `mjolnir` and
  the tenant database

### Requirement: Tenant backup

A host timer script SHALL dump each declared tenant to an off-host
B2 prefix (`backup-pg-tenants-b2.sh`). A runbook SHALL document restore
(recreate role + database) and exit `pg_dump` over the tenant
`DATABASE_URL`. Installing and enabling the timer on the live host is
operational, not a code SHALL.

#### Scenario: Exit dump from the tenant URL

- GIVEN a valid tenant `DATABASE_URL`
- WHEN `pg_dump` runs against that URL
- THEN the catalog is written to the caller’s destination
