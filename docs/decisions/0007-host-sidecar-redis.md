# ADR 0007 — Host Redis sidecar (durable, not a hotel)

**Status:** Proposed (2026-08-25) — awaiting advise on
`add-host-sidecar-redis`
**Change:** [`add-host-sidecar-redis`](../../openspec/changes/add-host-sidecar-redis/proposal.md)
**Living spec (after fold):** [`openspec/specs/host-redis/spec.md`](../../openspec/specs/host-redis/spec.md)
**First consumer:** Hypersigil Medusa (`REDIS_URL` in deploy secrets)
**Does not supersede:** ADR 0005 (Postgres tenant hotel) or ADR 0002
**Full argument:** [`openspec/changes/add-host-sidecar-redis/design.md`](../../openspec/changes/add-host-sidecar-redis/design.md)

## One screen

1. **systemd, not an OTP Port.** Redis must survive `just deploy`.
   The blob-door unit is the pattern. Restart Redis only when
   conf/unit/binary/password changed. Do not restart Elixir to
   install Redis. No extra just verb.
2. **Bind `:host_api_ip:6379` only** (default `10.200.0.1` on
   `dummy-mjolnir`). Unix socket for host backup. Never `0.0.0.0`.
   Fail closed if the dummy address is missing. Guest TCP is INPUT
   from `10.192.0.0/10`, not FORWARD.
3. **Not a hotel.** One process, one `requirepass`, `databases 1`
   (db 0). Isolation later via ACL if a second tenant appears. Do
   not `SELECT`-as-tenant. Do not copy ADR 0005 onto Redis.
4. **AUTH.** `REDIS_URL=redis://:<pass>@10.200.0.1:6379/0` merged
   into `/var/lib/mjolnir/deploy/secrets/<slug>.json` (first:
   `hypersigil-api`) without wiping `DATABASE_URL`. Not in
   `vm.json`. Unprovisioned guests cannot AUTH.
5. **Rename the guns.** Empty-string `FLUSHALL`, `FLUSHDB`, `DEBUG`,
   `CONFIG`, `SHUTDOWN`, `MODULE`, `REPLICAOF`, `SLAVEOF`. Keep
   `BGREWRITEAOF` for backup.
6. **AOF `everysec`.** Data dir `/var/lib/mjolnir/redis`. Named loss:
   up to one second on hard crash. Redis 7 AOF is a directory —
   backup copies the whole dir plus RDB. Off-host sink
   `b2:mimir-backups/mjolnir-redis/<hostname>/`. Exit dump:
   `redis-cli --rdb` over `REDIS_URL`.
7. **App wiring is out of this repo.** Hypersigil `medusa-config.ts`
   registers Redis. Mjolnir owes the daemon, the secret, the catalog
   row, and the backup.

## Built vs remaining

Built: nothing. No redis-server on the host.

Remaining: advise → install → B2 timer + restore runbook → Hypersigil
app register (other repo).
