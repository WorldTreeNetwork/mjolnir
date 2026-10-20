# add-guest-reattach

> **ACTIVE BUILD**

Bead `mjolnir-uepi.2`. Depends on `mjolnir-uepi.1` (closed). Blocks `mjolnir-uepi.3` and `mjolnir-uepi.4`.

**Rigor:** architecture

Preparation 2026-10-20: upstream probe `uepi-probe-stdio` (port close survives, SIGHUP kills, log file does not change that). Steer in `steer.md` replaces the parked classifier. Authority: `/run` plus a fleet restart, bounded to this shape. Outcome: revised, then accepted by opus-arch-review in `reviews/2026-10-20-advise-5.md` (guest-lifetime plus ADR 0014 Decision). The slice and scope prefix are per instance, the same way `tap_prefix` is. systemd `failed` is a death, and a loaded non-active unit name is cleared before cold resume. Authority for the following implementation: this campaign, including one cutover fleet restart. `mjolnir-uepi.3` and `mjolnir-uepi.4` are still open.

## Why

An Elixir restart reboots every guest because they share `mjolnir.service`'s cgroup. The port close does not kill them. A guest that outlives the BEAM still has to come back under one supervisor, including deaths that happen while the BEAM is down.

## What

- Capability `guest-lifetime` (new).
- ADR 0014 amended to the steer: detach on BEAM restart, a systemd watcher outside the service records every scope transition, the BEAM reattaches from that record.
- The watcher does not restart guests. The BEAM is the only restarter.
- Spawn and adopt stay later nodes. This change is the decision and the contract.

## Impact

- Capabilities: ADDED `guest-lifetime`
- ADRs: 0014 amended

## User journey & surfaces

Operator, from `systemctl restart mjolnir` and `mj kill`.

- Working: after the restart a guest that stayed up has the same id and the same uptime. `mj kill` still destroys that guest.
- Empty: no guests. The watcher has an empty slice. Restart does nothing to guests.
- Failed: the watcher saw the scope die during the outage. The BEAM cold-resumes that guest after the scope is inactive. It does not start a second hypervisor on the disk.
- Cutover: the first restart after this is deployed still reaps guests that were started inside the service cgroup. Guests started after that live in the slice. There is no runtime off switch.

No new UI because the surfaces are the existing service restart and `mj kill`.

## Out of scope

- Implementing the scope spawn (`mjolnir-uepi.3`) and the adopt path (`mjolnir-uepi.4`) in this change's code. The contract names them. The later nodes build them.
- A watcher that restarts guests (`Restart=on-failure`).
- Memory-snapshot thaw. Raising resume concurrency. Blob-door auth. A guest-agent deploy that skips a reboot.
