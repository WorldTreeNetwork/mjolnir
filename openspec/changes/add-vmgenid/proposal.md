# add-vmgenid

> **ACTIVE BUILD**

Bead `mjolnir-3y6.13`. Campaign grant on `mjolnir-3y6` (2026-10-23, "activate all" of the pinned ready-set).

## Why

A memory snapshot restores the guest CRNG along with RAM. Two restores of one image draw the same `/dev/urandom` stream until something reseeds it. `Mjolnir.Entropy.reseed` runs after `vm.resume`, so the first `getrandom` can win the race. VM Generation ID is the kernel mechanism: the hypervisor changes a 128-bit id on restore, and Linux 5.18+ `vmgenid` calls `add_vmfork_randomness()` before userspace is supposed to run.

## What

- Guest PVH kernel built with `CONFIG_VMGENID=y`. aarch64 direct-boot needs `acpi=on`.
- Host Cloud Hypervisor is a build that always exposes the VM Generation ID device (upstream v54.0, no config knob). The entropy proof host was v53.0, which does not.
- Thaw still runs `Entropy.reseed` before reachability. That covers userspace generators (Iroh, Quinn, ring) and the notify race. VMGenID does not reseed those.
- Forking a second running VM from one memory image stays refused.

## Impact

- Capabilities: ADDED requirement on `vm-freeze`
- ADRs: none

## User journey & surfaces

No new UI because thaw is still `mj thaw` / `POST /api/snapshots/:name/thaw`. The operator sees the same parked VM come back. The difference is kernel CRNG state, not a new screen.

## Out of scope

- Replacing `Entropy.reseed` (it stays the userspace and race backstop).
- VMClock (clock disruption is `add-thaw-clock`).
- Building a CH fork if the packaged v54+ binary already has the device.
- The bead's original "two VMs forked from one snapshot diverge" check. Fork stays refused. Divergence is two sequential restores, or restore versus the pre-snapshot stream.

## Preparation

Outcome: revised. Upstream deps `mjolnir-3y6.15` and `mjolnir-3y6.1` are closed. CH v54.0 (2026-10-14) ships the device; the 2026-10-19 proof was v53.0 with zero VMGenID strings. Living spec `openspec/specs/vm-freeze/spec.md` at `62b43e5` has no generation-id requirement. Authority: pinned epic grant, this node only. Fresh advise is owed before act.
