# Tasks

- [x] Fresh advise after preparation
- [ ] Host `cloud-hypervisor` is a build with the VM Generation ID device (v54+), recorded in the proof note
- [ ] PVH guest kernel has `CONFIG_VMGENID=y`. A disposable thaw on `45.76.77.97` shows a new generation id before `/var/lib/mjolnir/vmlinux-ch` is replaced
- [ ] A `CONFIG_VMGENID` capture shows a guest-visible generation-id change. A `/dev/urandom` sample after `Entropy.reseed` is not that evidence
- [ ] `Entropy.reseed` still runs before vsock reachability, and before PTY, ticket, and gateway publish on a first thaw
- [ ] A second thaw while the first guest is running gets a new VM id, vsock CID, virtiofsd socket, and TAP name over a clone of the pinned rootfs. It has no gateway ticket. The first guest stays published, including when the second thaw fails
- [x] Advise owed: legacy versus `CONFIG_VMGENID` capture record, guest-visible generation-id evidence, and the second guest's vsock-only reachability are in the delta (reviews/2026-10-23-advise.md). Re-advise checks this box
