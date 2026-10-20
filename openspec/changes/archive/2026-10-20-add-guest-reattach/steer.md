# steer add-guest-reattach

**When.** 2026-10-20
**Depth.** explicit

## Decided
- Convergence: a systemd watcher outside the BEAM, then reattach (user)
  Why: Duke asked to detach on BEAM restart, keep a systemd watcher on every cloud-hypervisor VMM, and reattach when the BEAM is back. Guests survive the restart. Deaths during the outage are recorded by something that did not die with the BEAM. Coming back is reattach, not a cold boot of whoever is still alive.

## Skipped
- none

## Auto
- The watcher witnesses. It does not restart guests. (auto)
  Why: a unit with `Restart=on-failure` plus Reconcile is two supervisors. The BEAM remains the only restarter. While it is up it consumes the watcher's stream. While it is down the watcher appends scope transitions. On the way up the BEAM reattaches scopes the watcher still reports alive, cold-resumes the ones the watcher saw die, and finishes an interrupted stop or dormancy by stopping that scope. A `:failed` guest is not started again. The scope unit name stays the single child id, so a second VMM is not started until that scope is inactive.

## Feeds change
Amend ADR 0014 so convergence is a monitor, not a parking lot. The child is `mjolnir-<id>.scope` under `mjolnir-vms.slice`. A small systemd unit outside `mjolnir.service` watches that slice and records active, inactive, and exit status, including while the BEAM is down. Orchestrator shutdown detaches and does not signal the slice. On startup the BEAM reads the watcher before Cleanup deletes sockets or TAPs and before Reconcile. Alive and identified scopes are attached, with no `vm.boot` and no second LUKS unlock. Scopes the watcher saw die are cold-resumed only after the scope is inactive. Interrupted `:stopped` and `:dormant` finish by stopping the scope. `:failed` stops the scope and does not boot. A pid that is not in that VM's scope is not our child. virtiofsd and cloud-hypervisor die together with the scope, one event, one restart. The port `:exit_status` is replaced by the watcher event. `:dormant` is a real row. Unresolved is a backoff that uses the existing resume-failure limit, not a permanent state.
