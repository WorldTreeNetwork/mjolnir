# Tasks

- [x] Fresh advise after the 2026-11-19 send-back. Same reader (`fable-arch-review`). The contract to review is this directory after that send-back: items 1–7 each have a requirement sentence and a scenario. Do not implement from the earlier draft.
- [x] Amend the delta for send-back items 1–7 (budget, host actor, JSON shapes, guest self-exit, exact command line and 1 vCPU / 512 MiB, one exchange, timeout and status 2/3).
- [ ] Spike H1 on morphie only if advise accepts. Cloud Hypervisor 54 at `~/ch54/cloud-hypervisor`. /32 TAP. No product code in the spike. Do not use the Framework laptop.
- [ ] Kind `unikernel` on HTTP spawn, `mj spawn`, MCP, and persisted `spawn_config`. Linux default unchanged. Kernel allow-list. Pin stored.
- [ ] Boot skips rootfs clone, agent injection, virtiofsd, and the vsock wait. Command line is only the three `reflect.*` words.
- [ ] Host-side message matches the JSON contract. Factorial and forever fixtures from homoiconic `793b583`. Wrong pin refused. Second caller gets `unikernel_busy`.
- [ ] `mj kill` removes the tap and the scope. Self-exit becomes `:stopped` / `guest_exit` with no data-loss resume. Restart returns `unikernel_restart_refused`.
- [ ] `mix test` stays green for existing Linux spawns.

## Out of scope

- Editing the homoiconic tree.
- Closing homoiconic bead `homoiconic-q59.17`.
- `reflect.wire_port`.
- A TCP server on the guest.
- Filtering the image's plain UDP port.
