## ADDED Requirements

### Requirement: Declared tenant database

The OTP-managed Postgres sidecar SHALL, when an operator declares a
tenant identifier matching `^[a-z_][a-z0-9_]*$`, idempotently create
a `CREATE DATABASE` of that name owned by a LOGIN role of the same
name. That role SHALL have DDL and DML on its database and SHALL NOT
have `CONNECT` on database `mjolnir`. Control-plane roles
`mjolnir_admin` and `mjolnir_sites` SHALL NOT be reused as the tenant
role.

#### Scenario: First tenant hypersigil

- GIVEN the sidecar is up and tenant `hypersigil` is not present
- WHEN `Tenants.ensure("hypersigil")` (or the operator command) runs
- THEN database `hypersigil` exists
- AND role `hypersigil` can CREATE TABLE in that database
- AND role `hypersigil` cannot connect to database `mjolnir`

#### Scenario: Ensure is idempotent

- GIVEN tenant `hypersigil` already exists
- WHEN ensure runs again
- THEN it returns success
- AND existing catalog tables in that database are unchanged

### Requirement: Overlay TCP only

Tenant connections SHALL use TCP to the reserved host-from-guest
address `:host_api_ip` (default `10.200.0.1`) on port 5432. That
address SHALL be assigned on the host before postgres starts and
SHALL be excluded from `Network.allocate_ip/1`. `listen_addresses`
SHALL be that address only — not `*`, not empty. If the address is
missing, postgres start SHALL fail (no fallback to `*` or
`0.0.0.0`). Postgres SHALL NOT listen on `0.0.0.0` or the
default-route NIC. Unix-socket peer authentication SHALL remain the
path for the BEAM to database `mjolnir`. TCP authentication SHALL be
scram-sha-256. `pg_hba` host lines SHALL be per-tenant-database,
source `10.200.0.0/10`, scram-sha-256.

#### Scenario: Guest with secret can migrate

- GIVEN tenant `hypersigil` and a guest holding that DATABASE_URL as a managed secret
- WHEN the guest runs application DDL (Medusa `db:migrate` or equivalent)
- THEN the DDL applies in database `hypersigil`

#### Scenario: Unprovisioned guest is not in pg_hba

- GIVEN a guest on `10.200.0.0/10` with no tenant secret
- WHEN it connects to `10.200.0.1:5432` as an unknown role
- THEN Postgres rejects authentication

#### Scenario: Public NIC is closed

- GIVEN the sidecar is serving tenants
- WHEN a client connects to port 5432 on `0.0.0.0` or on the default-route NIC
- THEN there is no Postgres handshake

#### Scenario: Bind IP missing fails closed

- GIVEN `:host_api_ip` is not assigned on the host
- WHEN postgres starts
- THEN start fails
- AND `listen_addresses` is not rewritten to `*` or `0.0.0.0`

### Requirement: Secrets stay out of snapshots

`Tenants.ensure/1` SHALL write `DATABASE_URL` to
`/var/lib/mjolnir/deploy/secrets/<slug>.json` (the path
`Deploy.Orchestrator` reads). The password SHALL be injected at
service-VM spawn (managed secrets). Builder layers and release
snapshots SHALL NOT contain the password. Tenant roles SHALL NOT be
listed in `pg_ident.conf`. Rotation is `ALTER ROLE` plus rewrite of
that JSON and a redeploy of the app VM.

#### Scenario: Snapshot does not contain the password

- GIVEN a release snapshot built for the tenant app
- WHEN the snapshot filesystem is searched for the tenant password
- THEN there are no matches

#### Scenario: PUBLIC cannot walk the hotel

- GIVEN tenants `hypersigil` and `other`
- WHEN role `hypersigil` connects to database `mjolnir` or `other`
- THEN CONNECT is denied
- AND `PUBLIC` has been revoked CONNECT on those databases

### Requirement: Tenant backup

Each declared tenant database SHALL be dumped on a schedule to an
off-host sink in the `forgejo-backup` shape (object storage, not a
path on the postgres disk). A documented restore SHALL recreate the
LOGIN role and the database from that object. A tenant SHALL also be
dumpable via `pg_dump` over the same TCP `DATABASE_URL` (exit path).

#### Scenario: Off-host dump after the timer fires

- GIVEN tenant `hypersigil` with at least one table
- WHEN the backup timer has fired
- THEN an object for database `hypersigil` exists in the off-host sink
- AND it is not stored only under `/var/lib/mjolnir/pg`

#### Scenario: Restore returns the catalog

- GIVEN an off-host dump of `hypersigil`
- WHEN an operator restores it into a fresh database of that name
- THEN previously written rows are queryable
- AND the LOGIN role exists

#### Scenario: Exit dump from the tenant URL

- GIVEN a valid tenant `DATABASE_URL`
- WHEN `pg_dump` runs against that URL
- THEN the catalog is written to the caller’s destination

