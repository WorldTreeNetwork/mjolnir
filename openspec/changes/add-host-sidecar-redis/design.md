# Design — host Redis sidecar (not a hotel)

Canonical ADR index:
[`docs/decisions/0007-host-sidecar-redis.md`](../../../docs/decisions/0007-host-sidecar-redis.md).
This file is the full argument.

**Status:** Proposed — awaiting advise.
**Change:** `add-host-sidecar-redis`
**First consumer:** Hypersigil Medusa (sessions via `connect-redis`;
cache / event-bus / locking / BullMQ if the app enables those modules)
**Does not supersede:** ADR 0005 (Postgres hotel) or ADR 0002.

## Problem

`mj deploy` boots a fresh service VM and stops the previous one.
Anything on that rootfs is gone. Medusa 2.19 stores sessions in Redis
(`connect-redis`) and can also put cache, the event bus, and BullMQ
there. ADR 0005 explicitly left `REDIS_URL` unwired. The live host has
no `redis-server`. Hypersigil deploy secrets have `DATABASE_URL` and
no `REDIS_URL`.

Three shapes survived intend:

1. Redis inside the app VM, data dir virtio-fs-mounted from the host.
2. Redis as an OTP Port next to Postgres.
3. Redis as a host systemd unit on `:host_api_ip`, like the blob door.

Duke picked (3). (1) couples Redis lifetime to the guest and to a
mount contract. (2) dies on every `just deploy` because Elixir restart
is Cleanup-kills-VMs → Reconcile-resumes; an OTP Port Redis would drop
every session with the BEAM. Sessions are why this sidecar exists.

## What is true in code today

- `:host_api_ip` default `10.200.0.1` is assigned `/32` on
  `dummy-mjolnir` (`scripts/bootstrap-host-ubuntu.sh`).
  `Network.allocate_ip/1` refuses it.
- Tenant Postgres is `10.200.0.1:5432` (OTP Port, scram). Blob door is
  `10.200.0.1:7222` (systemd). Guest TCP to the dummy is **INPUT**, not
  FORWARD (LEARNINGS 2026-08-19).
- `Mjolnir.Postgres.Tenants.write_secret/4` merges into
  `/var/lib/mjolnir/deploy/secrets/<slug>.json` and does not wipe other
  keys (`lib/mjolnir/postgres/tenants.ex` `Map.put("DATABASE_URL", …)`).
- `scripts/deploy.sh` always runs `scripts/install-blob-door.sh` and
  does not add a just verb per sidecar.
- No redis-server. No UFW 6379. No catalog row.

## Decision 1 — systemd unit, not an OTP Port

`systemd/mjolnir-redis.service` + `scripts/install-redis.sh`, same
shape as `mjolnir-blob-door`. Distro `redis-server` binary (Ubuntu
package); **disable** Debian/Ubuntu `redis-server.service` if present
so we do not inherit `bind 127.0.0.1`.

`just deploy` / `scripts/deploy.sh` calls the install script. The
script restarts the Redis unit **only** when unit, `redis.conf`, ACL
file, or binary changed (hash compare). A no-op deploy leaves Redis
and its clients alone. Installing or restarting Redis must not
`mix release` or restart `mjolnir.service`.

`Type=notify`, `supervised systemd`, `User=redis`,
`ReadWritePaths=` the data dir and runtime dir.
`ProtectSystem=strict`.

## Decision 2 — one overlay IP, INPUT, fail closed

- Bind `10.200.0.1:6379` only. `unixsocket` on
  `/run/mjolnir-redis/redis.sock` (0600, redis:redis) for host backup.
  Not `0.0.0.0`. Not `::`. Not the public/default-route NIC. Not
  `127.0.0.1` as the only bind (TAP guests cannot hit host loopback).
- Install script fails closed if `10.200.0.1/32` is missing on
  `dummy-mjolnir` — same check as `install-blob-door.sh`. Never rewrite
  bind to `*` / `0.0.0.0`.
- UFW/iptables: `allow from 10.192.0.0/10 to 10.200.0.1 port 6379`
  (INPUT). Bootstrap grows the same helper as 5432/7222.
- `protected-mode yes` is belt; AUTH is the gate.

Do not invent a second dummy or `10.255.255.1`.

## Decision 3 — one password, not a hotel

v1 is one process, one `requirepass`, `databases 1` (only db 0).
No `SELECT`-as-tenant. No second instance. No ACL user per app.

`REDIS_URL=redis://:<pass>@10.200.0.1:6379/0`.

Unprovisioned guests can open TCP (UFW allows the TAP) and cannot
AUTH. Default spawn does not inject the secret. The locator is the
managed secret, **not** `/etc/mjolnir/vm.json` (same as
`DATABASE_URL`).

When a second tenant appears, the next change may add ACL users.
That is not this change. Do not copy ADR 0005’s `CREATE DATABASE`
hotel onto Redis.

## Decision 4 — deny the guns, keep the backup commands

`rename-command` empty-string (applies to every connection, including
the host): `FLUSHALL`, `FLUSHDB`, `DEBUG`, `CONFIG`, `SHUTDOWN`,
`MODULE`, `REPLICAOF`, `SLAVEOF`.

Keep `BGREWRITEAOF`, `SAVE`, `BGSAVE` — the host backup script needs
them. Do not `ACL DENY @dangerous`: that category includes
`BGREWRITEAOF`.

Restore is stop-unit → replace data dir → start. Nobody needs
`FLUSHALL`.

## Decision 5 — AOF everysec, named loss, data off `@vms`

```
appendonly yes
appendfsync everysec
appenddirname appendonlydir
dir /var/lib/mjolnir/redis
```

`everysec` = up to **one second** of writes lost on a hard crash.
Name it; do not pretend `always` (too slow) or `no` (lie). RDB is an
extra snapshot (`save` defaults or a coarse `save 3600 1`), not the
durability story.

Redis 7+ AOF is a **directory** (`appendonlydir`), not a single
`appendonly.aof`. Backup copies the whole `dir` (AOF dir + `dump.rdb`).

No `maxmemory` in v1. If a later change sets one, policy is
`noeviction` so sessions are not silently dropped.

## Decision 6 — secrets merge, same path as the hotel

`mix mjolnir.redis.ensure --slug hypersigil-api`:

- If `/etc/mjolnir/redis.pass` (0600) is missing, generate
  (`:crypto.strong_rand_bytes` / `openssl rand`) and write it, then
  restart Redis so `requirepass` matches.
- Read `/var/lib/mjolnir/deploy/secrets/<slug>.json` if present.
- `Map.put("REDIS_URL", url)` — do **not** drop `DATABASE_URL` or
  any other key.
- Write 0600.

`install-redis.sh` may generate the password and unit; the mix task
is the operator surface that stamps the app secret. First slug:
`hypersigil-api`. Invocation is an operator command, not sidecar
bootstrap on every BEAM start.

Rotation = new password + rewrite JSON + restart Redis + redeploy
the app VM.

Password lives in `/etc/mjolnir/redis.pass` (host) and in that JSON
(host). Never in a guest snapshot, never in `vm.json`, never in
logs.

## Decision 7 — off-host backup is owed, not a follow-up wish

Same shape as `backup-pg-tenants-b2.sh`:

1. Host timer: unix-socket `BGREWRITEAOF`, wait until rewrite
   finishes, `rclone copy` `/var/lib/mjolnir/redis/` →
   `b2:mimir-backups/mjolnir-redis/<hostname>/`. Not a path on the
   Redis disk as the only copy. Bucket is `mimir-backups` (rclone
   key is scoped there; do not invent a new bucket).
2. Restore runbook: stop unit, replace data dir from the object,
   start, `redis-cli PING` + a known key.
3. Exit: from a guest holding `REDIS_URL`,
   `redis-cli --rdb dump.rdb -u "$REDIS_URL"` walks the session
   store off the host.

Timer enable on the live host is operational, same as the Postgres
tenant timer.

## Tradeoff (the one we are taking)

**Medusa sessions share fate with one host Redis process, not with
the BEAM, and not with a guest rootfs.**

Isolation is bind address + password + renamed commands, not a
hardware VM boundary. A bad `redis.conf` or a full disk takes
Hypersigil sessions down without taking Sites or the orchestrator.
The gain is cutover-safe app VMs and `just deploy` that does not
wipe logins. The cost is a second durable daemon to operate (backup,
restore, AUTH). Hotel isolation is deferred: one password, db 0, until
a second tenant forces ACL.

## What we are not deciding

- App-side `medusa-config.ts` Redis modules — Hypersigil repo.
- Encrypting AOF at rest (host disk / LUKS is a different epic).
- Cross-host Redis replication.
- Putting Medusa uploads in Redis.
- Making every `mj deploy` app a Redis client. The secret is explicit.
