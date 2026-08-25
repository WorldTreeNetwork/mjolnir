# Tasks

Owed while this change is ACTIVE BUILD. Beads in parens.
Do not `act` until advise accept / accept-with-nits.

## Owed before re-advise (2026-08-25)

Advise `send-back`. Do not `act`. Do not flip the proposal banner.
See `reviews/2026-08-25-advise.md`.

- [x] Decision 7 / spec “Off-host backup”: host timer is a **quiesced
      whole-dir snapshot** (stop unit, copy `/var/lib/mjolnir/redis/`,
      start). Named downtime: seconds. Not live `rclone` of
      `appendonlydir` after `BGREWRITEAOF`. Restore replaces that same
      dir (AOF + RDB together). Do not restore RDB-only onto
      `appendonly yes` — Redis loads AOF. Exit `redis-cli --rdb` over
      `REDIS_URL` stays as the leave-with-the-keys path, not the host
      timer object. *(spec/design/ADR amended 2026-08-25; implement
      boxes below still open)*

## Architecture (`mjolnir-g193.1`)

- [x] ADR 0007 filed at `docs/decisions/0007-host-sidecar-redis.md`
      (Proposed until advise; Accepted after). Pointer from
      `docs/architecture.md`. Bead text that said “ADR 0006” is wrong —
      0006 is mailbox-as-spool.
- [x] Living delta `openspec/changes/add-host-sidecar-redis/specs/host-redis/spec.md`
      (ADDED). Fold later copies it to `openspec/specs/host-redis/spec.md`.
- [x] Advise accept (reader **not** Grok — author family). Banner stays
      ACTIVE BUILD until fold. *(accept-with-nits 2026-08-25-readvise;
      human pick via `/run --until roll`)*

## Install (`mjolnir-g193.2`) — blocked on .1

- [x] Distro `redis-server` on the host; disable stock `redis-server.service`
- [x] `systemd/mjolnir-redis.service` + `redis.conf` under `/etc/mjolnir`
      (dir `/var/lib/mjolnir/redis`, bind `10.200.0.1:6379`, unixsocket
      `/run/mjolnir-redis/redis.sock`, `appendonly yes`,
      `appendfsync everysec`, `databases 1`, `requirepass`,
      `rename-command` for FLUSHALL/FLUSHDB/DEBUG/CONFIG/SHUTDOWN/MODULE/REPLICAOF/SLAVEOF)
- [x] `scripts/install-redis.sh`: fail closed if dummy `10.200.0.1/32`
      missing; never bind `0.0.0.0`; restart unit only if
      conf/unit/binary/password hash changed; does not restart Elixir
- [x] Ride `scripts/deploy.sh` / `just deploy`. No `just deploy-redis`
- [x] Bootstrap UFW/iptables INPUT `10.192.0.0/10` → `10.200.0.1:6379`
      (same helper shape as 5432/7222)
- [x] `mix mjolnir.redis.ensure --slug hypersigil-api` merges `REDIS_URL`
      into `/var/lib/mjolnir/deploy/secrets/hypersigil-api.json` without
      dropping `DATABASE_URL`
- [x] Catalog: `docs/guide/host-sidecars.md` row, README sidecar table,
      CLAUDE.md one-liner. Not `vm.json`
- [x] Tests / live proof: `ss` listen `10.200.0.1:6379` only; unauth
      AUTH refused; guest with `REDIS_URL` SET/GET; AOF survives
      `SIGKILL` of redis-server; `FLUSHALL` is unknown; `just deploy`
      no-op does not restart Redis

## Backup (`mjolnir-g193.3`) — blocked on .2

- [x] `scripts/backup-redis-b2.sh`: stop unit, rclone copy
      `/var/lib/mjolnir/redis/` →
      `b2:mimir-backups/mjolnir-redis/<hostname>/`, start unit
      (quiesced whole-dir snapshot; not live AOF copy)
- [x] `scripts/systemd/mjolnir-redis-backup.{service,timer}` (daily,
      RandomizedDelaySec, same shape as pg-tenants)
- [x] Runbook `docs/runbooks/host-redis.md`: restore (stop, replace
      dir, start) + exit `redis-cli --rdb` over `REDIS_URL`
- [x] Restore exercised once on the live host or a throwaway data dir

## Handoffs (not checkboxes)

- Hypersigil `medusa-config.ts` Redis module registration — app repo
- Redis hotel / ACL per tenant — later, if a second tenant appears
- Timer enable on the live host is operational after the units exist
  *(enabled 2026-08-25)*
