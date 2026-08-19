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

Tenant connections SHALL use TCP to the host overlay address already
used by guests to reach host services (`10.255.255.1`) on port 5432.
`listen_addresses` SHALL NOT be `*` or empty. The public NIC
(currently `45.76.77.97`) SHALL NOT accept Postgres. Unix-socket peer
authentication SHALL remain the path for the BEAM to database
`mjolnir`. TCP authentication SHALL be scram-sha-256.

#### Scenario: Guest with secret can migrate

- GIVEN tenant `hypersigil` and a guest holding that DATABASE_URL as a managed secret
- WHEN the guest runs application DDL (Medusa `db:migrate` or equivalent)
- THEN the DDL applies in database `hypersigil`

#### Scenario: Public NIC is closed

- GIVEN the sidecar is serving tenants
- WHEN a client connects to `45.76.77.97:5432`
- THEN the connection is refused or times out without a Postgres handshake

### Requirement: Secrets stay out of snapshots

The tenant role password SHALL be host-escrowed and injected at
service-VM spawn (managed secrets). Builder layers and release
snapshots SHALL NOT contain the password. Rotation is `ALTER ROLE`
plus rewrite of the escrow file and a redeploy of the app VM.

#### Scenario: Snapshot does not contain the password

- GIVEN a release snapshot built for the tenant app
- WHEN the snapshot filesystem is searched for the tenant password
- THEN there are no matches

### Requirement: Tenant backup

Each declared tenant database SHALL be dumped on a schedule to a host
path that is not a VM BTRFS subvolume. A documented restore SHALL
recreate the database from a dump without rebuilding from application
disk.

#### Scenario: Dump exists after the timer fires

- GIVEN tenant `hypersigil` with at least one table
- WHEN the backup timer has fired
- THEN a dump file for database `hypersigil` exists off `@vms`

#### Scenario: Restore returns the catalog

- GIVEN a dump of `hypersigil`
- WHEN an operator restores it into a fresh database of that name
- THEN previously written rows are queryable
