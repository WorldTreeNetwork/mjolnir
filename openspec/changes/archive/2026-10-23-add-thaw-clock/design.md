# add-thaw-clock

## Context

Laptop hibernate injects sleeptime in the guest because the guest ran `timekeeping_suspend` before the image. A Cloud Hypervisor snapshot does not. VMClock's `disruption_marker` is the device that tells a guest the counter jumped. We do not have that device.

`CLOCK_REALTIME` is what certs and logs read. `CLOCK_MONOTONIC` is what Quinn idle timers use. Stepping only the wall clock is what hibernate does. The monotonic gap is why connections must be dropped rather than waited out; that drop is not this change.

## Decision

Set wall time before publish. Try to do it while the restored VM is still paused, so userspace never runs on snapshot-time. If the only tool is a guest-agent call, it runs after `vm.resume` and the reachability gate stays closed until it returns.

## Residual

A paused clock write that the hypervisor cannot do leaves a window for processes that were already running in the snapshot. The gate stops new host-side sessions. It does not stop those processes.
