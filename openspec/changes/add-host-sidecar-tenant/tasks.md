# Tasks

- [x] ADR 0004 filed; ADR 0002 item 7 marked superseded; pointer from `docs/architecture.md`
- [ ] Overlay TCP listener on reserved `:host_api_ip` (`10.200.0.1:5432`), not `''`, not `0.0.0.0`, not the public NIC
- [ ] scram-sha-256 for host/TCP; Unix-socket peer auth unchanged for the BEAM
- [ ] `Mjolnir.Postgres.Tenants.ensure/1` as specified in design Decision 3
- [ ] First tenant `hypersigil` (slug `hypersigil-api`); password in `deploy/secrets/hypersigil-api.json`
- [ ] Unprovisioned guest still cannot authenticate to sidecar Postgres
- [ ] Off-host tenant dump timer (B2 / forgejo-backup shape) + restore notes + tenant-URL `pg_dump` exit
- [ ] Tests: bootstrap still creates `mjolnir` + `mjolnir_sites` without DDL; tenant migrate-class DDL works on the tenant DB; not listening on `0.0.0.0:5432`; allocate_ip never returns `10.200.0.1`
- [x] Amend PENDING `add-buzz-local-runtime` so declared tenants are not re-forbidden

## Owed before re-advise (2026-08-19)

Advise `send-back`. Do not `act`. Do not flip the proposal banner.
See `reviews/2026-08-19-advise.md`.

- [x] Overlay bind IP is reserved + assigned (dummy or `lo`) in host bootstrap, excluded from `Network.allocate_ip/1`, up before postgres starts. Reconcile with `:host_api_ip` (`10.200.0.1`). Stop citing `forgejo-runner.service` as proof of a guest→host bind this tree does not create. Fail closed if the address is missing — never fall back to `*` / `0.0.0.0`. *(spec/design amended 2026-08-19; implement boxes above still open)*
- [x] Keep living requirement **name** `Host sidecar is control-plane only` (OpenSpec MODIFIED replaces by name). Edit the body; do not rename.
- [x] `Tenants.ensure` contract: password generation; write `DATABASE_URL` to `/var/lib/mjolnir/deploy/secrets/<slug>.json` (the path `Deploy.Orchestrator` actually reads); `REVOKE CONNECT FROM PUBLIC` on `mjolnir` and tenant DBs + re-grant owners; invocation (command + declared list); exact `pg_hba` host/scram lines; tenant roles stay out of `pg_ident.conf`. *(spec/design amended; implement still open)*
- [x] Backup sink is off-host (`forgejo-backup` B2 shape), not merely off `@vms`. Restore recreates role + database. Tenant `pg_dump` over the same TCP path is the catalog exit test. *(spec/design amended; implement still open)*
- [x] Amend PENDING `add-buzz-local-runtime` “Stateful production workloads … SHALL run real Postgres inside their own VM, not on the host sidecar” **in this change**, so it does not re-forbid declared tenants. Not a post-accept handoff.
