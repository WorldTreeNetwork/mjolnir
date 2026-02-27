# Mjolnir Work Log

## 2026-02-26 — Cloud Hypervisor transition, bug fixes, test harness

### Changed
- Default hypervisor switched from Firecracker to Cloud Hypervisor v50.0
- `boot_args` now includes `root=/dev/vda rw` for CH PVH boot
- `vsock_cid` generated per-VM from MD5(UUID) instead of hardcoded 3
- VM boot failures exit `:normal` (transient restart no longer cascades)
- Router returns error JSON on spawn failure instead of crashing
- TAP cleanup wrapped in try/rescue to prevent race conditions

### Added
- `lib/mjolnir/cleanup.ex` — orphan hypervisor/TAP sweep on startup
- `lib/mjolnir/dormant_registry.ex` — ETS registry for dormant VM metadata
- Guest agent auto-injection into rootfs at boot (`inject_guest_agent/1`)
- Inter-VM messaging: `POST /api/vms/:id/messages`, buffered during boot
- Dormant VM listing: `GET /api/dormant`
- EventBus, DormantRegistry added to supervision tree
- 6 new test files (101 unit tests total, 0 failures)
- `docs/plans/test-harness-spec.md` — test taxonomy and priorities
- `docs/plans/current-status.md` — handoff doc with open issues
- Full server rebuild: code, guest agent (musl), rootfs (Ubuntu 24.04)

### Updated
- `CLAUDE.md` — reflects CH default, new modules, supervision tree, known issues
- `docs/architecture.md` — hypervisor layer, supervision tree, key paths, workspace layout

### Known Issues
- CH `vm.create` returns 400 Bad Request — debug log staged in `client.ex`
