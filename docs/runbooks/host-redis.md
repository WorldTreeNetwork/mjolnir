# Host Redis sidecar (ADR 0007)

Durable Redis on `:host_api_ip:6379` (`10.200.0.1`). systemd, not an
OTP Port. AOF `everysec`. One password, db 0 — not a hotel.
Guest catalog: [`guide/host-sidecars.md`](../guide/host-sidecars.md).

## Install

Rides `just deploy` / `scripts/deploy.sh` (`scripts/install-redis.sh`).
No `just deploy-redis`. The install step does not restart Elixir.
Restart Redis only when unit/conf/binary/password changed.

```bash
sudo bash scripts/install-redis.sh
mix mjolnir.redis.ensure --slug hypersigil-api
```

Merges `REDIS_URL` into `/var/lib/mjolnir/deploy/secrets/<slug>.json`
without wiping `DATABASE_URL`. Other keys: `mj secrets set <app> KEY`
([deploying-an-app](../guide/deploying-an-app.md#secrets-stay-out-of-the-snapshot)).
`mj deploy --name hypersigil-api` reads that file.

## Proof

```bash
ss -lntp | grep 6379          # 10.200.0.1:6379 only, not 0.0.0.0
# from a guest with REDIS_URL:
redis-cli -u "$REDIS_URL" PING
redis-cli -u "$REDIS_URL" SET durable 1
redis-cli -u "$REDIS_URL" GET durable
redis-cli -u "$REDIS_URL" FLUSHALL   # unknown command
```

## Exit dump (`REDIS_URL`)

```bash
redis-cli --rdb dump.rdb -u "$REDIS_URL"
```

That walks the session store off the host. It is **not** the host
timer object.

## Off-host dump

`scripts/backup-redis-b2.sh` stops `mjolnir-redis`, copies
`/var/lib/mjolnir/redis/` to
`b2:mimir-backups/mjolnir-redis/<hostname>/<stamp>/`, starts the unit.
Named downtime: seconds.

```bash
install -m 0755 scripts/backup-redis-b2.sh /usr/local/bin/
cp scripts/systemd/mjolnir-redis-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mjolnir-redis-backup.timer
```

`install-redis.sh` already copies those files. Enabling the timer on
the live host is operational.

## Restore

1. `systemctl stop mjolnir-redis`
2. Replace `/var/lib/mjolnir/redis/` with the B2 snapshot (AOF
   directory **and** RDB from the same stamp).
3. `chown -R redis:redis /var/lib/mjolnir/redis`
4. `systemctl start mjolnir-redis`
5. `redis-cli -u "$REDIS_URL" GET durable`

Do **not** restore RDB-only onto `appendonly yes` — Redis loads AOF.

## Rotate

```bash
mix mjolnir.redis.ensure --slug hypersigil-api --rotate
```

Rewrites the password files, restarts Redis, rewrites `REDIS_URL`.
Redeploy the app VM so it picks up the secret.
