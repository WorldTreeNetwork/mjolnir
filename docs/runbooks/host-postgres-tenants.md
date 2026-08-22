# Host sidecar tenant databases (ADR 0005)

Declared tenants live as `CREATE DATABASE` on the OTP Postgres sidecar.
TCP is `10.200.0.1:5432` (scram). The BEAM still uses the Unix socket.
Guest catalog of all overlay sidecars:
[`guide/host-sidecars.md`](../guide/host-sidecars.md).

## Provision

```bash
mix mjolnir.pg.tenant ensure hypersigil --slug hypersigil-api
```

Writes `/var/lib/mjolnir/deploy/secrets/hypersigil-api.json` with
`DATABASE_URL` (merges; does not wipe other keys).

`mj deploy --name hypersigil-api` reads that file. The name is slugged
(lowercase; anything outside `[a-z0-9_-]` → `_`) and looked up as
`<deploy_secrets_dir>/<slug>.json`. `--name hypersigil` looks for
`hypersigil.json` and misses. See
[`../guide/deploying-an-app.md`](../guide/deploying-an-app.md).

## Exit dump (tenant URL)

```bash
pg_dump "$DATABASE_URL" --no-owner --format=plain > hypersigil.sql
```

Must exit 0. That is the catalog walking out with you.

## Off-host dump

`scripts/backup-pg-tenants-b2.sh` → `b2:mimir-backups/mjolnir-pg-tenants/<host>/`.
Timer: `scripts/systemd/mjolnir-pg-tenants-backup.{service,timer}`.

Install:

```bash
install -m 0755 scripts/backup-pg-tenants-b2.sh /usr/local/bin/
cp scripts/systemd/mjolnir-pg-tenants-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mjolnir-pg-tenants-backup.timer
```

## Restore

1. Recreate the LOGIN role + database: `mix mjolnir.pg.tenant ensure <name> --slug <slug> --rotate` (or `CREATE ROLE` / `CREATE DATABASE` by hand).
2. `psql "$DATABASE_URL" < dump.sql`
3. If the password rotated, rewrite `deploy/secrets/<slug>.json` and redeploy the app VM.
