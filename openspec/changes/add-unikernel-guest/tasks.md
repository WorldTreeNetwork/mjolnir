# Tasks

- [x] Fresh advise after the 2026-11-19 send-back. Same reader (`fable-arch-review`). The contract to review is this directory after that send-back: items 1–7 each have a requirement sentence and a scenario. Do not implement from the earlier draft.
- [x] Amend the delta for send-back items 1–7 (budget, host actor, JSON shapes, guest self-exit, exact command line and 1 vCPU / 512 MiB, one exchange, timeout and status 2/3).
- [x] Verify H1 on morphie, Cloud Hypervisor 54, with a Mjolnir /32 TAP. The original pre-code spike was not recorded; the now-landed product client passes the reproducible hardware acceptance run (see evidence/2026-11-23-morphie.md).
- [x] Kind `unikernel` on HTTP spawn, `mj spawn`, MCP, and persisted `spawn_config`. Linux default unchanged. Kernel allow-list. Pin stored.
- [x] Boot skips rootfs clone, agent injection, virtiofsd, and the vsock wait. Command line is only the three `reflect.*` words.
- [x] Host-side message matches the JSON contract. Factorial and forever fixtures from homoiconic `793b583`. Wrong pin refused. Second caller gets `unikernel_busy`. Silence is `unikernel_timeout`.
- [x] `mj kill` removes the tap and the scope. Self-exit becomes `:stopped` / `guest_exit` with no data-loss resume. Restart returns `unikernel_restart_refused`.
- [x] `mix test` stays green for existing Linux spawns. Five full runs, 1943 passed, 0 failed; the remaining failures were test defects, fixed under `mjolnir-tinp` (see evidence/2026-11-23-morphie-aa2ab1a.md).

## Out of scope

- Editing the homoiconic tree.
- Closing homoiconic bead `homoiconic-q59.17`.
- `reflect.wire_port`.
- A TCP server on the guest.
- Filtering the image's plain UDP port.

## Validation record

- [First morphie run](evidence/2026-11-23-morphie.md), image from homoiconic `793b583`.
- [Second morphie run](evidence/2026-11-23-morphie-aa2ab1a.md), image built fresh from homoiconic `aa2ab1a` (`reflect-net.elf` sha256 `f8fdc41c…1d15`), with the [full transcript](evidence/2026-11-23-morphie-aa2ab1a-full.log) and the green `mix test` gate.
