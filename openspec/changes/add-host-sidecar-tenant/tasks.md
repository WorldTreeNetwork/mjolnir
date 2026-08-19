# Tasks

- [ ] ADR 0004 filed; ADR 0002 item 7 marked superseded; pointer from `docs/architecture.md`
- [ ] Overlay TCP listener on the host gateway address (`10.255.255.1:5432`), not `''`, not `0.0.0.0`, not the public NIC
- [ ] scram-sha-256 for host/TCP; Unix-socket peer auth unchanged for the BEAM
- [ ] `Mjolnir.Postgres.Tenants.ensure/1` (or equivalent) creates database + LOGIN role with DDL on that database only; no CONNECT on `mjolnir`
- [ ] First tenant `hypersigil`; password in managed secrets, never in a build snapshot
- [ ] Unprovisioned guest still cannot authenticate to sidecar Postgres
- [ ] Tenant `pg_dump` timer + restore notes; dumps off the VM BTRFS volume
- [ ] Tests: bootstrap still creates `mjolnir` + `mjolnir_sites` without DDL; tenant migrate-class DDL works on the tenant DB; public NIC `:5432` closed
- [ ] Handoff (not a box): after advise accept, amend PENDING `add-buzz-local-runtime` “in-guest Postgres for production” sentence so it does not re-forbid declared tenants
