# add-host-sidecar-tenant

> **ACTIVE BUILD**

**Rigor:** architecture

## Why

Hypersigil Medusa needs a durable Postgres that survives `mj deploy` cutover. The OTP sidecar is already the host’s supervised Postgres. ADR 0002 item 7 and living spec `buzz-local-client` forbid using it as a tenant hotel: Unix socket only, `listen_addresses=''`, `--auth-host=reject`, guests have no path, service roles cannot DDL. Duke activated the reopen: same process, separate `CREATE DATABASE` per declared tenant, TCP on reserved `:host_api_ip`. Advise 2026-08-19 sent back the first draft (unassigned `10.255.255.1`, renamed MODIFIED requirement, vacuous backup). Spec/design amended; do not `act` until re-advise accepts.

## What

- Add capability `host-postgres`: tenant database provision, overlay TCP listener, scram auth, DDL-capable tenant role, backup.
- MODIFIED `buzz-local-client` requirement “Host sidecar is control-plane only” so the catalog rule stays for `mjolnir` and Buzz logs, and a declared tenant database is the exception.
- ADR 0004 supersedes ADR 0002 item 7 only.
- First tenant: `hypersigil` (consumed by hypersigil-store-backend `add-mjolnir-manifest`).

## Impact

- Capabilities: ADDED `host-postgres`; MODIFIED `buzz-local-client`
- ADRs: `docs/decisions/0004-host-sidecar-tenant-hotel.md` (new). Pointer from `docs/architecture.md`. ADR 0002 remains; item 7 is superseded.

## User journey & surfaces

Duke, shipping **Hypersigil Medusa** onto a Mjolnir service VM, from the existing surfaces `mj` / `mj deploy` / host SSH.

1. Operator (or bootstrap) declares tenant `hypersigil`. **Today: off** — bootstrap only creates database `mjolnir`.
2. Guest service VM starts with `DATABASE_URL` pointing at the sidecar tenant DB (managed secret, not baked). **Today: failed** — `listen_addresses=''`, `--auth-host=reject`.
3. `medusa db:migrate` runs inside the guest (DDL). **Today: failed** — even if it could connect, tenant roles do not exist and `mjolnir_sites` cannot DDL.
4. `GET /health` is `OK`. Catalog rows persist across a later `mj deploy` cutover (new service VM, same `DATABASE_URL`). **Today: off**.
5. A default guest with no tenant secret still cannot reach Postgres. **Today: works** (must keep working).

No new UI because the outcome already reaches `mj deploy`, managed secrets, and `GET /health` on the service VM.

## Out of scope

- Redis, Medusa file uploads — hypersigil `add-mjolnir-manifest`
- `mjolnir.toml`, CI, DNS — hypersigil `add-mjolnir-manifest`, `add-ci-deploy`, `add-dns-api`, `add-forgejo-mirror`
- Putting Buzz community events on the sidecar — remains forbidden; tracked by `add-buzz-local-runtime` (relay VM)
- Re-opening Distributed Erlang, nsec handling, or Admit
- Publishing Postgres on the public NIC
- A third host-from-guest IP besides `:host_api_ip` (`10.200.0.1`)
