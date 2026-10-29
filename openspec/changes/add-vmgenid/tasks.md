# Tasks

- [x] Fresh advise after preparation
- [x] Host `cloud-hypervisor` is a build with the VM Generation ID device (v54+), recorded in the proof note
- [ ] PVH guest kernel has `CONFIG_VMGENID=y`. A disposable thaw on `45.76.77.97` shows a new generation id before `/var/lib/mjolnir/vmlinux-ch` is replaced
- [ ] A `CONFIG_VMGENID` capture shows a guest-visible generation-id change. A `/dev/urandom` sample after `Entropy.reseed` is not that evidence
- [ ] `Entropy.reseed` still runs before vsock reachability, and before PTY, ticket, and gateway publish on a first thaw
- [ ] A second thaw while the first guest is running gets a new VM id, vsock CID, virtiofsd socket, and TAP name over a clone of the pinned rootfs. It has no gateway ticket. The first guest stays published, including when the second thaw fails
- [x] Advise owed: legacy versus `CONFIG_VMGENID` capture record, guest-visible generation-id evidence, and the second guest's vsock-only reachability are in the delta (reviews/2026-10-23-advise.md). Re-advise checks this box

## Proof note

2026-10-26, `45.76.77.97`: `cloud-hypervisor v54.0`. `strings` on that binary contains `VmGenId`. `/var/lib/mjolnir/vmlinux-ch` is 46139936 bytes dated Mar 13 2026 and contains no `vmgenid` string. That fleet file was not replaced. Side kernel `/var/lib/mjolnir/vmlinux-ch-vmgenid` is 34175448 bytes, built Oct 29 2026 from `scripts/build-kernel.sh`, which refuses to install unless embedded `CONFIG_VMGENID=y` is present. Guest observation is `get_vmgenid` reading `/sys/firmware/vmgenid/generation_id` (32 hex digits). The stock ch-6.12.8 driver does not export that file; the build script adds it. A `/dev/urandom` sample is not an observation. The disposable thaw on that side kernel, and the second-guest thaw, are still open.
