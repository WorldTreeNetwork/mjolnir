# Tasks

Owed from 2026-09-10 advise send-back (F1–F4). Do not check a box
whose premise the live host still falsifies. Re-advise
(`reviews/2026-09-10-re-advise.md`, accept) reworded the units and
secrets tasks and added R2/R4/R6 lines.

- [x] ASK: DNS — `buzz.identikey.me` CNAME `identikey.me` → A `45.76.77.97` (verified 2026-09-10 at Cloudflare authoritative; apex moved off Linode). Same target as `auth.identikey.me`.
- [x] ASK (low, R4): explicit `buzz.identikey.me` A `45.76.77.97` or CNAME `vm.worldtree.network` so the hive does not follow the apex if it moves again — **leave CNAME to apex** (Duke 2026-09-20: don't bother pin)
- [x] Author: sync `design.md` D3 (drop the Linode `74.207.254.179` text) and D4 (`EnvironmentFile=` → `sh -lc`, see below) with these tasks
- [x] Correct `docs/gateway-routing.md` §"How to point a name" (stale wildcard Origin cert / `*.identikey.me` CNAME) or mark it aspirational
- [x] Native units in the guest (R3): skopeo extract of `ghcr.io/block/buzz:main`; Ubuntu Postgres **16** (24.04 default, not pgdg 17); Redis 7.0.15; MinIO RELEASE.2025-09-07. 4096 MB. No dockerd.
- [x] Cutover-free Registry adopt: `PUT /api/apps/:app` + `stateful` on `Entry` + Runtime refuse (tests green). **Host Elixir not bounced yet** — first hive row was `Registry.put` via `bin/mjolnir rpc`. `just deploy` lands the guard. No `mj app adopt` CLI yet (API is the contract).
- [x] Secrets: spawn `secrets_mode: managed` + secrets map. Units `sh -lc` sourcing `/run/mjolnir/secrets.env` as root. Not `mj secrets`.
- [x] Start units only after secrets.env exists; liveness on guest :3000
- [x] Domain + HTTP-01 cert: `https://buzz.identikey.me/_liveness` is 200 (cert issue via `mjolnir-gateway cert issue` as user `mjolnir`; API `systemd-run --collect` swallowed the success and 500'd)
- [x] Snapshot `buzz-relay-b0` (crash-consistent). Do not `mj freeze` as backup
- [x] Restore runbook: `docs/runbooks/buzz-relay-restore.md`
- [x] EYES: Desktop Join `wss://buzz.identikey.me` with the owner identity; confirm the owner is a *member row* of the seeded community (startup logged NIP-43 `member_count: 1`). Looked 2026-09-10: Duke — it's working.
- [x] Document Join URL + NIP-OA policy next to `docs/plans/initiatives/buzz-provider.md` § B0 (no new surface)
