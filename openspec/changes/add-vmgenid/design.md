# add-vmgenid

## Context

UAPI.14 VMGenID: the id changes on snapshot restore, clone, and backup recovery. It stays constant across pause/resume, reboot, and live migration. Linux credits it as a uniqueness signal, not as entropy, and forces an immediate CRNG reseed. Firecracker still reseeds from userspace before customer code runs, because the ACPI notify races the first `getrandom`.

## Decision

Upgrade the host hypervisor to a release that contains the device, and build the guest kernel with the driver. Do not patch v53. Keep the agent reseed in front of the reachability gate.

## Residual

Processes already running inside the guest can call `getrandom` in the window between vCPU resume and the notify. The reachability gate does not close that window. VMGenID narrows it relative to a pure userspace reseed. Userspace CSPRNGs are unchanged until they draw again after they know the generation changed.
