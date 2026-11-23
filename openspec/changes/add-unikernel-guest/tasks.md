# Tasks

- [x] Fresh advise after the 2026-11-19 send-back. Same reader (`fable-arch-review`). The contract to review is this directory after that send-back: items 1–7 each have a requirement sentence and a scenario. Do not implement from the earlier draft.
- [x] Amend the delta for send-back items 1–7 (budget, host actor, JSON shapes, guest self-exit, exact command line and 1 vCPU / 512 MiB, one exchange, timeout and status 2/3).
- [x] Verify H1 on morphie, Cloud Hypervisor 54, with a Mjolnir /32 TAP. The original pre-code spike was not recorded; the now-landed product client passes the reproducible hardware acceptance run (see evidence/2026-11-23-morphie.md).
- [x] Kind `unikernel` on HTTP spawn, `mj spawn`, MCP, and persisted `spawn_config`. Linux default unchanged. Kernel allow-list. Pin stored.
- [x] Boot skips rootfs clone, agent injection, virtiofsd, and the vsock wait. Command line is only the three `reflect.*` words.
- [x] Host-side message matches the JSON contract. Factorial and forever fixtures from homoiconic `793b583`. Wrong pin refused. Second caller gets `unikernel_busy`.
- [x] `mj kill` removes the tap and the scope. Self-exit becomes `:stopped` / `guest_exit` with no data-loss resume. Restart returns `unikernel_restart_refused`.
- [ ] `mix test` stays green for existing Linux spawns.

## Out of scope

- Editing the homoiconic tree.
- Closing homoiconic bead `homoiconic-q59.17`.
- `reflect.wire_port`.
- A TCP server on the guest.
- Filtering the image's plain UDP port.

## Validation record

See [morphie acceptance evidence](evidence/2026-11-23-morphie.md). The full-suite gate remains open for failures also reproduced on unchanged main; this change is not archived.
