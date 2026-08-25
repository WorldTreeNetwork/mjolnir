## ADDED Requirements

### Requirement: Overlay bind only

Host Redis SHALL listen on `:host_api_ip` port 6379 only (default
`10.200.0.1`). It SHALL NOT listen on `0.0.0.0`, `::`, the
default-route NIC, or loopback as the only bind. If `10.200.0.1/32`
is not assigned on `dummy-mjolnir`, install and start SHALL fail and
SHALL NOT rewrite bind to `*` or `0.0.0.0`. Guest TCP SHALL be allowed
as INPUT from `10.192.0.0/10` to that address and port. A unix socket
MAY exist for host backup and SHALL NOT be mounted into guests.

#### Scenario: Guest with secret can SET/GET

- GIVEN `10.200.0.1/32` is assigned on `dummy-mjolnir`
- AND Redis is running with `requirepass` and bind `10.200.0.1:6379`
- AND a TAP guest holds `REDIS_URL`
- WHEN the guest `SET` then `GET` a key
- THEN the values match

#### Scenario: Public NIC is closed

- GIVEN Redis is serving guests
- WHEN a client connects to port 6379 on `0.0.0.0` or on the
  default-route NIC
- THEN there is no Redis handshake

#### Scenario: Bind IP missing fails closed

- GIVEN `10.200.0.1` is not assigned
- WHEN `scripts/install-redis.sh` or the unit starts
- THEN it fails
- AND bind is not rewritten to `*` or `0.0.0.0`

### Requirement: AUTH required

TCP clients SHALL AUTH. Unprovisioned guests SHALL NOT receive
`REDIS_URL`. Default spawn SHALL NOT inject the password.
`REDIS_URL` SHALL live in `/var/lib/mjolnir/deploy/secrets/<slug>.json`
and SHALL NOT appear in `/etc/mjolnir/vm.json`.

#### Scenario: Unprovisioned guest cannot AUTH

- GIVEN a TAP guest with no Redis secret
- WHEN it connects to `10.200.0.1:6379` and issues `PING` without AUTH
- THEN Redis refuses the command

### Requirement: One instance, not a hotel

v1 SHALL run one Redis process, `databases 1` (db 0 only), one
`requirepass`. It SHALL NOT treat `SELECT` as tenant isolation. It
SHALL NOT start a second Redis for a second app.

#### Scenario: Only db 0 exists

- GIVEN Redis is up
- WHEN a client AUTH then `SELECT 1`
- THEN Redis returns an error

### Requirement: Dangerous commands renamed

`FLUSHALL`, `FLUSHDB`, `DEBUG`, `CONFIG`, `SHUTDOWN`, `MODULE`,
`REPLICAOF`, and `SLAVEOF` SHALL be renamed to the empty string so
they are unavailable on every connection. `BGREWRITEAOF`, `SAVE`, and
`BGSAVE` SHALL remain available for host backup.

#### Scenario: Guest FLUSHALL is unknown

- GIVEN a guest that has AUTH
- WHEN it sends `FLUSHALL`
- THEN Redis replies unknown command
- AND existing keys remain

### Requirement: AOF durability

Redis SHALL run `appendonly yes` and `appendfsync everysec` with data
dir `/var/lib/mjolnir/redis` (off `@vms`). A hard crash MAY lose up
to one second of writes. After a graceful restart or after `SIGKILL`
of `redis-server` followed by start, keys written more than one
second before the kill SHALL still exist.

#### Scenario: SIGKILL keeps keys

- GIVEN an AUTH client has `SET durable 1` and waited two seconds
- WHEN `redis-server` is `SIGKILL`ed and the unit starts again
- THEN `GET durable` returns `1`

### Requirement: Secrets merge

`Mjolnir.Redis.ensure/1` (or `mix mjolnir.redis.ensure --slug <slug>`)
SHALL write `REDIS_URL` into
`/var/lib/mjolnir/deploy/secrets/<slug>.json` by merging. Existing
keys including `DATABASE_URL` SHALL remain. The file SHALL be mode
0600. First slug is `hypersigil-api`.

#### Scenario: DATABASE_URL survives Redis ensure

- GIVEN `hypersigil-api.json` already contains `DATABASE_URL`
- WHEN `mix mjolnir.redis.ensure --slug hypersigil-api` runs
- THEN the file contains both `DATABASE_URL` and `REDIS_URL`
- AND `REDIS_URL` is `redis://:<pass>@10.200.0.1:6379/0`

### Requirement: Deploy does not bounce Redis with Elixir

`scripts/deploy.sh` SHALL install or reconcile the Redis unit and
SHALL NOT restart `mjolnir.service` in order to do so. A deploy that
did not change Redis conf, unit, password, or binary SHALL NOT
restart `mjolnir-redis.service`. There SHALL NOT be a
`just deploy-redis` recipe.

#### Scenario: No-op deploy leaves Redis pid

- GIVEN `mjolnir-redis.service` is active
- WHEN `scripts/deploy.sh` runs with no Redis conf/unit/binary change
- THEN the Redis main pid is unchanged
- AND `mjolnir.service` restart is not caused by the Redis install step

### Requirement: Off-host backup and exit dump

A host timer script SHALL copy the Redis data dir (AOF directory plus
RDB) to `b2:mimir-backups/mjolnir-redis/<hostname>/`. A runbook SHALL
document restore (stop unit, replace dir, start). A guest SHALL also
be able to dump via `redis-cli --rdb` over the same `REDIS_URL`
(exit path). Installing and enabling the timer on the live host is
operational, not a code SHALL.

#### Scenario: Exit dump from REDIS_URL

- GIVEN a valid `REDIS_URL` and at least one key
- WHEN `redis-cli --rdb dump.rdb -u "$REDIS_URL"` runs from a guest
- THEN the RDB is written on the caller’s side

#### Scenario: Restore returns keys

- GIVEN an off-host copy of the data dir that contains key `durable`
- WHEN an operator stops Redis, replaces `/var/lib/mjolnir/redis`,
  and starts the unit
- THEN `GET durable` returns the previous value
