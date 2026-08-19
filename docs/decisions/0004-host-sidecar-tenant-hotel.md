# ADR 0004 — Host Postgres sidecar as a tenant hotel

**Status:** Proposed (2026-08-19)
**Change:** [`add-host-sidecar-tenant`](../../openspec/changes/add-host-sidecar-tenant/proposal.md)
**Supersedes:** ADR 0002 item 7 only (“Host Postgres sidecar is schemas in one catalog DB, not a hotel”). Items 1–6 and 8–9 of ADR 0002 stand.
**First consumer:** Hypersigil Medusa (`~/work/VirtueInnova/hypersigil-store-backend`, change `add-mjolnir-manifest`)
**Full argument:** [`openspec/changes/add-host-sidecar-tenant/design.md`](../../openspec/changes/add-host-sidecar-tenant/design.md)

## One screen

1. **Control-plane catalog stays `mjolnir`.** Sites / admit / forge indexes remain schemas in that database. Peer auth over the Unix socket. Service roles still have no DDL there.
2. **Declared tenant apps get `CREATE DATABASE` in the same OTP-managed Postgres process.** One postgres, many databases. Not a second cluster. Not a schema inside `mjolnir`.
3. **Buzz event logs stay off the sidecar.** That half of ADR 0002 item 7 is unchanged.
4. **Guests have no path by default.** A tenant login is injected as a managed secret at spawn. Unprovisioned guests cannot reach the Unix socket or the tenant TCP listener.
5. **Tenant TCP binds the reserved host-from-guest address `:host_api_ip` (default `10.200.0.1`), port 5432.** That address is assigned on the host (dummy/`lo`) in bootstrap, excluded from `Network.allocate_ip/1`, and up before postgres starts. Not `0.0.0.0`. Not the public/default-route NIC. Missing bind IP is fail-closed — never fall back to `*`. Auth is scram-sha-256. Unix-socket peer auth is unchanged for the BEAM.
6. **Tenant roles can DDL** on their own database (Medusa migrations). They cannot connect to `mjolnir` and cannot see other tenant databases.
7. **Tenant data is source of truth.** It cannot be rebuilt from disk the way Sites indexes can. Backup of tenant databases is owed by this change.

## Built vs remaining

Nothing of this is built. ADR 0002 item 7 and living spec `buzz-local-client` still say “catalog, not a hotel.” This ADR is the reopen. Implement from `add-host-sidecar-tenant` after advise accept.
