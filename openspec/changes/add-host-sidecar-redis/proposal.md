# add-host-sidecar-redis

> **ACTIVE BUILD**
>
> Activated from chat 2026-08-25 (intend: durable Redis sidecar for
> Medusa sessions). Beads: `mjolnir-g193` and children `.1`–`.3`.
> Architecture: advise accept required before `act`. ADR number is
> **0007** (0006 is mailbox-as-spool). Author family is Grok — the
> advise reader must be a different family (ADR-005).

**Rigor:** architecture

Depends on folded ADR 0005 (`:host_api_ip` `10.200.0.1` on
`dummy-mjolnir`) and the blob-door overlay lesson (INPUT, not FORWARD;
ride `deploy.sh`; no extra just verb).

## Why

Hypersigil Medusa needs Redis that survives `mj deploy` cutover and
`just deploy` (Elixir restart). Postgres ADR 0005 left `REDIS_URL`
unwired on purpose. There is no `redis-server` on the host today.
Sessions, cache, event-bus, and BullMQ are source of truth for the
app — they cannot be rebuilt from disk the way Sites indexes can.

An OTP Port (the Postgres pattern) would die with the BEAM. Redis
must be a systemd unit, like the blob door.

## What

- Add capability `host-redis`: overlay Redis on `:host_api_ip:6379`,
  AUTH, AOF, INPUT, secrets merge, B2 backup.
- ADR 0007. Does **not** reopen ADR 0005 (Postgres stays the hotel).
- First consumer: Hypersigil Medusa (`REDIS_URL` in
  `deploy/secrets/hypersigil-api.json`). Wiring `medusa-config.ts` is
  the app repo, not this change.

## Impact

- Capabilities: ADDED `host-redis`
- ADRs: `docs/decisions/0007-host-sidecar-redis.md` (new). Pointer
  from `docs/architecture.md` and catalog row on
  `docs/guide/host-sidecars.md`.
- Living `buzz-local-client` “Host sidecar is control-plane only”
  is **not** MODIFIED — that SHALL is about the OTP Postgres process.

## User journey & surfaces

Duke, shipping **Hypersigil Medusa** onto a Mjolnir service VM, from
`mj deploy` / host SSH / guest shell.

1. Operator installs the Redis unit (rides `just deploy`). **Today: off**
   — no redis-server.
2. `mix mjolnir.redis.ensure --slug hypersigil-api` merges `REDIS_URL`
   into existing deploy secrets (does not wipe `DATABASE_URL`).
   **Today: off**.
3. Guest Medusa `connect-redis` SET/GET on `10.200.0.1:6379`.
   **Today: failed** — nothing listens; TAP cannot hit host loopback.
4. `just deploy` restarts Elixir / bounces VMs. Redis stays up; session
   keys still exist after the new VM AUTH. **Today: off**.
5. Host crash simulation: restore AOF+RDB from B2; sessions/queues
   return. **Today: off**.
6. Unprovisioned guest TCP without the password cannot AUTH. Bind is
   not `0.0.0.0`. **Today: n/a**.

No new UI because the outcome already reaches `mj deploy` managed
secrets and Medusa’s Redis client inside the guest.

## Out of scope

- Redis hotel (ACL users / `SELECT` as tenant / second instance) —
  named later if a second tenant appears
- Hypersigil `medusa-config.ts` / module registration — app repo
- TLS on the overlay — TAP is already private, same as Postgres
- Redis Cluster / Sentinel / replica
- Publishing 6379 on the public NIC
- A third overlay IP besides `:host_api_ip`
- Putting Buzz event logs on Redis
- Extra `just` verb (`just deploy-redis`) — rejected the same way as
  `just deploy-blob-door`
