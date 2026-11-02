# steer add-vmgenid

**When.** 2026-10-23
**Depth.** standard

## Decided
- Second thaw while the first VM is running: allow forks (user)
  Why: one memory image may back two running guests. This node grows vsock CID reallocation and virtiofsd socket rewriting so the second guest does not attach to the first guest's daemon. The two guests must not share a CRNG. The proposal's refusal is superseded.
- Guest-agent entropy reseed: keep it before publish (user)
  Why: VMGenID reseeds the kernel CRNG. Userspace generators (Iroh and the rest) keep snapshot state until they draw again. PTY, ticket, and gateway still wait for `Entropy.reseed`.
- Proof host: disposable thaw on the v54 server (user)
  Why: build the PVH kernel and thaw one disposable VM on `45.76.77.97`. Do not replace `/var/lib/mjolnir/vmlinux-ch` until that thaw shows a new generation id.
- Hypervisor patch: do not fork Cloud Hypervisor (auto)
  Why: v54.0 on that host already contains `VmGenId` / `VM_Gen_Counter`. The device has no config knob.
- Architecture: x86_64 PVH kernel only (auto)
  Why: this fleet is x86_64. AArch64 `acpi=on` is not this node.
- Folded siblings: do not reopen `add-thaw-clock`, `add-thaw-iroh-probe`, or `add-memory-snapshot-usage` (auto)
  Why: those contracts are in `openspec/specs/vm-freeze/spec.md`. This steer does not unland them.

## Skipped
- (none)

## Feeds change
Revise `add-vmgenid` so a second thaw of one memory image is supported while the first thawed VM is still running. That requires a new vsock CID and a new virtiofsd socket for the second guest, serving a clone of the pinned rootfs rather than the first guest's daemon. Both guests must observe different kernel CRNG streams. Keep `Entropy.reseed` in front of PTY, ticket, and gateway. Prove `CONFIG_VMGENID=y` with a disposable thaw on the v54 server before replacing the fleet boot kernel. Do not patch Cloud Hypervisor, do not add AArch64 work, and do not edit the folded clock, Iroh, or storage requirements. The task that says fork stays refused is no longer the direction. Fresh advise still precedes act. Banner stays ACTIVE BUILD.
