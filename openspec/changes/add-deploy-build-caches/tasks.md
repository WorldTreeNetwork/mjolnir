# Tasks

- [ ] `BTRFS`: create/snapshot/rename/delete helpers for `@caches/…` subvolumes, with a per-cache host lock
- [ ] `Deploy.BuildCache`: checkout (hint → current → empty), commit (success only; `current`/`prev`/`hint-*` rotation), discard; reap orphaned `work-*` at boot
- [ ] `Deploy.Builder`: checkout before boot; commit on success, discard on any failure or abort (including the existing guaranteed-teardown path)
- [ ] `Deploy.Orchestrator`: `cache-<name>` virtiofs mounts, `/cache/<name>` prelude, preset env vars
- [ ] Detector presets: cargo, bun/npm/pnpm, mise, apt
- [ ] `Deploy.Manifest`: `cache = [...] | false`, `[[cache.path]]`; refuse paths overlapping `/run/mjolnir`
- [ ] Trust: owner/app from the authenticated deploy; read-only checkouts for CI/Forgejo builds
- [ ] Progress lines: restored / empty / committed / discarded / off
- [ ] API + `mj cache ls|rm`; qgroup sizes; per-owner quota LRU; 30-day expiry
- [ ] Tests: two concurrent builds never share a writable dir; a failed build leaves `current` unchanged; cross-owner checkout impossible; CI checkout never commits; empty-cache and warm-cache builds give the same release file list and pass the same smoke check
- [ ] Measure a warm identikey rebuild over virtiofs vs local disk; record the number and the virtiofs-or-image decision in this change

## Owed from architecture advise — 2026-09-30

See [the independent review](reviews/2026-09-30-advise.md). Reconcile the design and normative scenarios before implementation; keep the disposition unchanged until separately activated.

- [ ] R1: Define cache-independent layer prerequisites and release materialization for Cargo and mise/Node, preserve existing start commands, reconcile the artifacts dependency, and specify cache-configuration keying; cover empty-cache partial hits and service boot without cache mounts.
- [ ] R2: Replace the two-rename atomicity claim with a concrete publication/recovery protocol; cover current/prev/repeated hints, durable metadata, reader/GC coordination, commit-error behavior, winner ordering, and interruption/race tests on btrfs.
- [ ] R3: Define durable build/VM/work ownership, writer quiescence, teardown ordering, safe orphan detection, and idempotent recovery; cover checkout/spawn failure, caller death, failed stop, and restart/reconciliation races.
- [ ] R4: Define server-trusted deploy/CI provenance and owner/app authorization for every cache operation; clarify disposable writable CI clones, restrict PR-readable credential/private-source/custom caches, validate names/paths/env/mount collisions, and add trust-forgery, cross-owner, and credential-sentinel scenarios.
- [ ] R5: Separate compiled-cache compatibility from fallback hints; define alias-rebuild/base/ABI/toolchain invalidation and late old-build commits, with an unchanged-source native-dependency rebuild scenario and a bounded custom-cache correctness contract.
- [ ] R6: Specify quota defaults, qgroup setup/health, shared-extent and work-generation accounting, hint bounds, concurrent admission/growth, active-build-safe eviction/remove, late repopulation, and EDQUOT/ENOSPC behavior; add pressure/expiry/race scenarios.
- [ ] R7: Make cold/warm tests force layer misses and prove compiler execution; preserve full-hit zero-VM behavior, test partial hits after eviction and source-sensitive outputs, and add R1–R6 failure/recovery/trust cases to the normative delta.
- [ ] R8: Define a reproducible virtiofs-versus-guest-local-disk benchmark and exact threshold, gated on resolving mjolnir-mne7; record the result before rollout and reconcile image-backend lifecycle/quota semantics if selected.
