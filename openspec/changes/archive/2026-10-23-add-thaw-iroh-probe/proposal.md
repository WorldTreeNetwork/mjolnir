# add-thaw-iroh-probe

> **ACTIVE BUILD**

Bead `mjolnir-3y6.8`. Campaign grant on `mjolnir-3y6` (2026-10-23, "activate all" of the pinned ready-set).

## Why

A thawed guest still holds Iroh/QUIC associations from capture time. Those associations are dead. A fresh vsock ping succeeds (`mjolnir-3y6.6` closed on that), so guest-agent health reports a VM nobody can reach.

## What

- After thaw, do not report the VM healthy, and do not publish it, until an Iroh reachability probe succeeds.
- A vsock ping is not that probe.
- The probe runs after entropy reseed and after the clock step.

## Impact

- Capabilities: ADDED requirement on `vm-freeze`
- ADRs: none

## User journey & surfaces

The operator runs `mj thaw` and then `mj doctor <id>` or reads VM status. A VM whose Iroh node has not come back is unhealthy, not running. `mj connect` is not offered while the probe is failing.

## Out of scope

- Aborting QUIC before the snapshot and latching reconnect until thaw. That is the right way to avoid waking a dead association, and it is not this bead. File it separately if we build it.
- Gratuitous ARP / `VIRTIO_NET_S_ANNOUNCE`. That repairs L2 only.

## Preparation

Outcome: still valid as a health gate. Deps closed. Living spec requires entropy reseed before reachability and does not mention Iroh. vsock-after-thaw is closed as not the bug. Authority: pinned epic grant, this node only. The quiesce latch discussed beside this bead is out of scope so this contract does not grow a second design.
