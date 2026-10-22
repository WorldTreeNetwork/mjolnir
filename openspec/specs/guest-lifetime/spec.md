# guest-lifetime

What is built. Folded from
[`add-guest-reattach`](../../changes/archive/2026-10-20-add-guest-reattach/proposal.md)
on 2026-10-20. Decisions live in
[`docs/decisions/0014-guest-outlives-orchestrator.md`](../../../docs/decisions/0014-guest-outlives-orchestrator.md).

## Purpose

An Elixir restart must not reboot a guest that outlives the BEAM.
Each guest runs in a per-instance systemd scope outside
`mjolnir.service`. A witness records scope state and does not restart
guests. The BEAM reattaches an active scope and cold-resumes a dead one.

## Requirements

### Requirement: Guests live in a sibling slice
Each guest's cloud-hypervisor and every virtiofsd for that guest, including `extra_mounts`, SHALL run in one systemd scope outside `mjolnir.service`. The slice name and the scope-name prefix are per instance, derived from config the same way `tap_prefix` is. Production uses `mjolnir-vms.slice` and `mjolnir-<id>.scope`. That unit name SHALL be the single child id. Identity matches when the record's id is that scope name. A BEAM SHALL subscribe to, classify, and stop only scopes in its own slice. The TAP is a netdev keyed by that scope id. The BEAM deletes or recreates it on stop and on cold resume. It is not a member of the scope. virtiofsd and cloud-hypervisor SHALL die with the scope.

#### Scenario: Orchestrator restart detaches
- GIVEN a guest running in its scope
- WHEN the Elixir service restarts
- THEN the scope is not signaled
- AND the guest process keeps the same pid

#### Scenario: Stop kills that scope
- GIVEN a guest running in its scope
- WHEN the operator stops that VM
- THEN that scope is killed
- AND `mjolnir.service` is not killed

#### Scenario: Another instance does not reap this slice
- GIVEN a guest running in this instance's slice
- AND a second BEAM on the same host uses a different slice namespace
- WHEN that second BEAM starts and its own StateStore is readable
- THEN the guest's scope is not stopped

### Requirement: A watcher outside the BEAM records scope transitions
A systemd unit outside `mjolnir.service` SHALL record active, inactive, failed, and exit status or systemd Result where available, for every scope in that instance's slice, including while the BEAM is down. The record SHALL survive a host reboot. "Cannot be read" means the record file is absent or unparseable. A readable file with no entry for an id is not unreadable. The watcher SHALL NOT restart a guest. The BEAM SHALL subscribe to the live stream before it reads the record at startup, so no transition is lost between the two. Scope units have no `ExecMainStatus`. Result, or unknown, is enough.

#### Scenario: Death during the outage is not lost
- GIVEN the BEAM is down and a scope exits
- WHEN the BEAM starts
- THEN the watcher record shows that scope died
- AND the BEAM does not treat the guest as still alive

### Requirement: Startup touches a slice member only through classification
`Cleanup.sweep` SHALL NOT kill a process because its command line contains the socket directory. A member of this instance's slice SHALL be stopped only by the rules in this spec.

#### Scenario: A true orphan is stopped
- GIVEN the StateStore was readable
- AND a scope in this instance's slice has no record
- WHEN the BEAM starts
- THEN that scope is stopped
- AND no other scope is stopped because of a process listing

### Requirement: An unreadable store or watcher record does not stop a living guest
If the StateStore cannot be read, startup SHALL NOT kill a slice member, cold-resume a guest, or delete that guest's socket or TAP. If the watcher record file is absent or unparseable, a scope systemd reports active whose StateStore intent is `:running` SHALL still be attached. An unreadable watcher record SHALL NOT count toward resume-failure retirement, and SHALL NOT cause a living scope to be stopped. A unit that is gone, inactive, or `failed` is a death under the missing-unit requirement, including when this file cannot be read. It is not left waiting.

#### Scenario: The watcher record is unreadable and the scope is alive
- GIVEN the watcher record file cannot be read
- AND systemd reports `mjolnir-<id>.scope` active
- AND the StateStore intent is `:running`
- WHEN the BEAM starts
- AND this state lasts past the resume-failure limit
- THEN the scope is still running
- AND the guest is attached
- AND the scope is not stopped

### Requirement: Liveness is the current systemd state
Whether a scope is alive SHALL be the current systemd state of that instance's `mjolnir-<id>.scope`. The watcher record SHALL supply history and exit status or systemd Result, including a death while the BEAM was down. If the record says the scope was active and systemd says the unit is inactive, `failed`, or not loaded, that SHALL be a death with unknown exit status. ActiveState `failed` is a death the same way inactive is. Before a cold resume the BEAM SHALL clear a loaded non-active unit of that name, for example with `reset-failed` or `CollectMode=inactive-or-failed` at spawn, so the restart is not refused because the name is still loaded. Cold resume SHALL be handed to Reconcile's existing plan: `restart_policy: :never` finalizes to `:stopped` unless revive is authorized, and SHALL NOT boot that guest.

#### Scenario: The host rebooted
- GIVEN the watcher record survived the reboot and last said the scope was active
- AND systemd has no such unit
- AND restart policy is not `:never`
- WHEN the BEAM starts
- THEN the guest is handed to Reconcile and cold-resumed
- AND the exit status is unknown

#### Scenario: No watcher entry and no unit
- GIVEN the watcher record is readable and has no entry for this id
- AND systemd has no `mjolnir-<id>.scope` or it is inactive
- AND the StateStore intent is `:running`
- AND restart policy is not `:never`
- WHEN the BEAM starts
- THEN that is a death with unknown exit status
- AND the guest is handed to Reconcile and cold-resumed

#### Scenario: An OOM-killed scope is cold-resumed
- GIVEN systemd reports the scope ActiveState `failed`
- AND the StateStore intent is `:running`
- AND restart policy is not `:never`
- WHEN the BEAM classifies that guest
- THEN the loaded unit name is cleared before the cold resume
- AND the guest is handed to Reconcile and cold-resumed
- AND `resume_failures` does not grow because the name was still loaded

#### Scenario: Cutover reaps then cold-resumes
- GIVEN guests were started inside `mjolnir.service` and have no watcher entry
- WHEN the first restart after this deploy reaps those processes
- THEN each `:running` guest whose policy is not `:never` is cold-resumed
- AND a `:never` guest is finalized and not booted

### Requirement: The BEAM is the only restarter
On startup the BEAM SHALL subscribe to the watcher before reading the record, and SHALL do both before deleting sockets or TAPs and before Reconcile. It SHALL NOT delete the cloud-hypervisor API socket, the vsock UDS, or the virtiofsd sockets of a scope classified as attach, or of a scope not yet classified. An alive identified scope SHALL be attached with no `vm.boot` and no second managed LUKS unlock. A scope the watcher saw die, or a `:running` record with no watcher entry and no active unit, SHALL be handed to Reconcile only after that scope is inactive or `failed` and a loaded non-active unit of that name has been cleared. Interrupted `:stopped` or `:dormant` SHALL finish by stopping the scope and SHALL NOT boot. Operator stop and dormancy SHALL persist intent `:stopped` or `:dormant` before the scope is signaled. A `:failed` guest SHALL NOT be booted. A pid outside that VM's scope SHALL NOT be treated as the guest. While the BEAM is up, a watcher event SHALL be the death signal in place of the port `:exit_status`. A guest that cannot be classified SHALL back off using the existing resume-failure limit and SHALL NOT stay unresolved forever.

The first deploy that turns this on still reaps guests that were started inside `mjolnir.service`. Those guests come back by the cold-resume row above. After that restart, new guests are in the slice. There is no runtime off switch.

#### Scenario: Reattach a living guest
- GIVEN the watcher reports the scope alive and the identity matches
- WHEN the BEAM starts
- THEN the guest is attached
- AND uptime is unchanged
- AND LUKS unlock does not run again

#### Scenario: Cold resume only after the scope is gone
- GIVEN the watcher saw the scope die
- AND restart policy is not `:never`
- WHEN the BEAM starts
- THEN no second hypervisor is started until that scope is inactive or `failed` and its loaded name has been cleared
- AND the guest is handed to Reconcile and cold-resumed

#### Scenario: A never guest that died is not booted
- GIVEN `restart_policy: :never`
- AND the scope died during the outage
- WHEN the BEAM starts
- THEN the record is finalized to `:stopped`
- AND the guest is not booted

#### Scenario: Failed guest stays down
- GIVEN the record intent is `:failed` and the scope is still alive
- WHEN the BEAM starts
- THEN the scope is stopped
- AND the guest is not booted

#### Scenario: Interrupted stop finishes
- GIVEN the record intent is `:stopped` and the scope is still alive
- WHEN the BEAM starts
- THEN the scope is stopped
- AND nothing is booted

#### Scenario: Interrupted dormancy finishes
- GIVEN the record intent is `:dormant` and the scope is still alive
- WHEN the BEAM starts
- THEN the scope is stopped
- AND nothing is booted

### Requirement: An active scope is attached, not resumed
Reconcile, from startup or from a Health.Monitor tick, SHALL attach and SHALL NOT cold-resume a `:running` record whose scope systemd reports active. A scope start refused because the unit is already active SHALL NOT count toward resume-failure retirement. Orchestrator shutdown SHALL detach and SHALL NOT signal the scope. `VM.stop` SHALL stop the scope. A crash of that VM's GenServer SHALL detach. The scope SHALL end when cloud-hypervisor exits, so an active scope means a living VMM.

#### Scenario: The GenServer exits and the scope stays up
- GIVEN the BEAM is up
- AND a VM GenServer exits while its scope stays active
- WHEN Reconcile runs
- THEN the guest is attached
- AND it is not booted
- AND `resume_failures` does not grow

### Requirement: A missing unit is a death even if the watcher record cannot be read
A `:running` record whose unit is gone, inactive, or `failed` SHALL be a death with unknown exit status whether or not the watcher record is readable, and SHALL be handed to Reconcile's plan. This does not stop a scope systemd reports active. A loaded non-active unit of that name SHALL be cleared before the cold resume.

#### Scenario: Corrupt record and no unit
- GIVEN the watcher record file cannot be read
- AND systemd has no active `mjolnir-<id>.scope`
- AND the StateStore intent is `:running`
- AND restart policy is not `:never`
- WHEN the BEAM starts
- THEN the guest is handed to Reconcile and cold-resumed

#### Scenario: A death while the BEAM is up
- GIVEN the BEAM is running and attached to a scope
- WHEN the watcher reports that scope exited
- THEN the BEAM handles that event as the death signal
- AND it does not wait for a port `:exit_status`
