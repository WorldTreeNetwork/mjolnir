# add-thaw-clock

> **ACTIVE BUILD**

Bead `mjolnir-3y6.7`. Campaign grant on `mjolnir-3y6` (2026-10-23, "activate all" of the pinned ready-set).

## Why

A restored guest keeps snapshot-time wall clock. Cert windows, cron, and logs skew by the park, which can be days. `CLOCK_MONOTONIC` does not include that gap, so idle timers armed before the freeze do not notice it.

## What

- Before the thawed VM is reachable, its wall clock agrees with host time.
- Do not step `CLOCK_MONOTONIC` by the park duration.
- Prefer a hypervisor clock update while vCPUs are still paused (CH restores KVM clock from the snapshot; that value is snapshot-time unless we overwrite it before `vm.resume`).
- If the clock can only be stepped by the guest agent after resume, hold PTY, ticket, and gateway until that step succeeds. Processes already inside the guest can still observe the old time in that window. That limit is the contract.

## Impact

- Capabilities: ADDED requirement on `vm-freeze`
- ADRs: none

## User journey & surfaces

No new UI because the operator uses `mj thaw`. After thaw, `date` inside the guest matches host time before `mj connect` is offered.

## Out of scope

- Adding a VMClock device. That is the purpose-built clock-disruption signal and is not in the hypervisor we run.
- Stepping `CLOCK_MONOTONIC` (that expires every armed timer at once).
- NTP slew after the step. One step is the contract; chrony may run afterwards.

## Preparation

Outcome: revised. Bead note hoped CH v52 `#7932` ("KVM clock restored before vCPUs are resumed") was the fix. That restores the saved clock, which is snapshot-time. Living spec has no clock requirement. Deps `3y6.1` and `3y6.15` are closed. Authority: pinned epic grant, this node only.
