# Tasks

- [x] Pure rule builder `Mjolnir.Network.published_port_rules/6`, with tests.
- [x] `Mjolnir.PublishedPorts`: parse, admission, claim, install, sync, remove by tag, sweep.
- [x] Spawn option, `spawn_config`, resume, dormant restore, thaw. Old records read as no ports.
- [x] Install after the TAP in both boot paths. Remove on stop and on a failed boot. Keep across a detach.
- [x] Cleanup sweep. Reconcile releases the rules of a record it retires or finalizes.
- [x] `POST /api/vms` field and named errors. `GET /api/vms/:id` lists the ports.
- [x] `mj spawn --publish-udp`, `mj info`, MCP `spawn_vm`.
- [x] Docs: `CLAUDE.md`, `docs/guide/getting-started.md`, `docs/guide/coming-from-docker.md`.
- [ ] Datagram round trip on a real host (Framework laptop). Bead `mjolnir-rwsw`. The laptop was unreachable on 2026-11-20.
- [ ] Fold into `openspec/specs/published-ports/spec.md` and archive.
