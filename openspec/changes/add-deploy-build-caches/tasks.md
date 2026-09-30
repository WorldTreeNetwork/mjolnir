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
