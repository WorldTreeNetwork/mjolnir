# add-vmgenid

## Context

UAPI.14 VMGenID: the id changes on snapshot restore, clone, and backup recovery. It stays constant across pause/resume, reboot, and live migration. Linux credits it as a uniqueness signal, not as entropy, and forces an immediate CRNG reseed. Firecracker still reseeds from userspace before customer code runs, because the ACPI notify races the first `getrandom`.

## Decision

Use the v54.0 device already on `45.76.77.97`. Do not patch Cloud Hypervisor. Build the x86_64 PVH kernel with `CONFIG_VMGENID=y` and prove a disposable thaw on that host before replacing `/var/lib/mjolnir/vmlinux-ch`. Keep the agent reseed in front of the reachability gate.

A second thaw while the first guest is running is a new guest. It gets a new VM id, a new vsock CID, a new virtiofsd socket, and a new TAP name. The socket serves a clone of the pinned rootfs. Guest IP, MAC, and Iroh key stay as captured, so the second guest is not published on the gateway and does not get a ticket. It is reachable over its own vsock after the agent reseed. The first guest stays published, including when the second thaw fails. The first thaw of a parked source id is unchanged: that same id comes back and is published after reseed.

The snapshot records whether the kernel that was running at capture had `CONFIG_VMGENID`. The fleet kernel file is not inside that image. Old images have no record: they thaw under the agent reseed and do not claim a generation-id change. A recorded capture that does not show a new guest-visible generation id is not published. Two different urandom streams after the agent reseed do not prove the driver ran.

## Residual

Processes already running inside the guest can call `getrandom` in the window between vCPU resume and the notify. The reachability gate does not close that window. VMGenID narrows it relative to a pure userspace reseed. Userspace CSPRNGs, including ones that already copied bytes into their own state, stay at the snapshot until they draw again. `Entropy.reseed` is that backstop. It does not prove the driver ran.
