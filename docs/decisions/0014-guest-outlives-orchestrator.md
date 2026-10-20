# ADR 0014: A guest outlives an orchestrator restart

**Status:** Accepted 2026-10-20 by opus-arch-review (advise-5). The decision and the contract are accepted. `mjolnir-uepi.3` and `mjolnir-uepi.4` are still the implementation. Not shipped.

The 2026-10-20 steer replaces the parked classifier. A systemd watcher outside `mjolnir.service` records every scope transition, including while the BEAM is down, and does not restart guests. The BEAM is the only restarter. On the way up it reattaches living scopes, cold-resumes scopes the watcher saw die only after the scope is inactive or `failed` and the unit name is clear, finishes interrupted stop or dormancy by stopping the scope, and does not boot a `:failed` guest. The watcher event replaces port `:exit_status`. `:dormant` is a real case. Unresolved is the existing resume-failure backoff, not a permanent state. The earlier Opus caution (starttime row versus cold-resume, missing `:dormant`, no death signal) is what this revision closes. Spawn and adopt stay later nodes.

## Decision

Cloud Hypervisor and every virtiofsd for that guest, including `extra_mounts`, run in one systemd scope. The slice name and the scope-name prefix are per instance, derived from config the same way `tap_prefix` is. Production uses `mjolnir-<id>.scope` under `mjolnir-vms.slice`. A BEAM classifies and stops only scopes in its own slice. The TAP is a netdev keyed by that scope id. The BEAM deletes or recreates it. It is not a member of the scope. The scope ends when cloud-hypervisor exits. The scope name is the child id.

Detach is a third teardown outcome, beside stop and preserve-rootfs. Orchestrator shutdown detaches: it drops its handles and does not signal the slice. `VM.stop` kills that scope only. Preserve-rootfs still means the disk is kept when a boot fails.

A systemd unit outside `mjolnir.service` watches that instance's slice and records active, inactive, failed, and exit status or systemd Result where available, including while the BEAM is down. Scope units have no `ExecMainStatus`. It does not restart guests. The BEAM is the only restarter. While the BEAM is up, a watcher event is the death signal. The port `:exit_status` is not.

Liveness is systemd's current state of that instance's scope. The watcher supplies history. If the record says active and systemd says the unit is inactive, `failed`, or not loaded, that is a death with unknown exit status. `failed` is a death the same way inactive is. Before a cold resume the BEAM clears a loaded non-active unit of that name, so the restart is not refused because the name is still loaded.

On startup the BEAM reads the watcher before it deletes sockets or TAPs, before Reconcile, and before any process kill. It does not delete the cloud-hypervisor API socket, the vsock UDS, or the virtiofsd sockets of a scope classified as attach, or of a scope not yet classified. `Cleanup.sweep` does not kill a process because its command line contains the socket directory. A slice member is stopped only by these rules:

- The StateStore cannot be read: touch nothing. No kill, no cold resume, no socket or TAP delete.
- The watcher record file is absent or unparseable, and systemd says the scope is active with intent `:running`: attach. That does not count toward retirement and does not stop the scope. A missing entry in a readable file is not this case.
- No record, and the store was readable: stop that scope. That is a true orphan.
- The scope is alive and the intent is `:running`: attach, from startup or from a Health.Monitor tick. Do not cold-resume. A refused start because the unit is already active does not count as a resume failure. No `vm.boot`. No second LUKS unlock. `extra_mounts` stay on the record. `:never` is a restart policy, not an intent. Orchestrator shutdown and a crash of that VM's GenServer detach. `VM.stop` stops the scope.
- The watcher saw the scope die, systemd says the unit is gone, inactive, or `failed`, or a readable record has no entry and the unit is not active: hand the guest to Reconcile after the scope is inactive or `failed` and a loaded non-active unit of that name has been cleared. `:never` finalizes and does not boot unless revive is authorized.
- Intent `:stopped` or `:dormant` and the scope is alive: stop the scope. Do not boot.
- Intent `:failed` and the scope is alive: stop the scope. Do not boot.
- A pid that is not in that scope is not the guest.
- Anything else: backoff with the existing resume-failure limit, then `:failed`. It does not stay unresolved.

The first restart after this is deployed still reaps guests that were started inside `mjolnir.service`. That is the cutover. There is no runtime off switch. After it, an Elixir-only deploy does not reboot guests that are in the slice. A guest-agent update still reboots the guests that must pick up the new binary, and the deploy path says so.

## Probe (mjolnir-uepi.1)

Throwaway id `uepi-probe-stdio` on the hypervisor. A separate Elixir BEAM, not the production node (pid stayed `1164307`). No `systemctl restart`.

Closing the Erlang port that owns stdout, and halting that BEAM, left both `virtiofsd` and `cloud-hypervisor` alive. Pointing stdout and stderr at a log file did not change that: both still survived. Closing the pipe without a signal also left both alive. An explicit `SIGHUP` killed both (`virtiofsd` exit 1, `cloud-hypervisor` signal 1).

The probe is not "die on close". Log files are not a precondition for surviving the port close. They are still how these processes should log, because a later write to a dead pipe was not part of the probe. The production restart reaps guests by the service cgroup and by `Cleanup.sweep`, which is why the slice move is the survival claim, not the stdout pipe.

## Why not the alternatives

A higher resume concurrency still reboots every guest. Memory thaw restores RAM after tearing the source VMM down. These guests are already running. `KillMode=process` leaves the ports and the sweep in place, and it leaks VMMs when the BEAM is really gone.

## Out of scope

Blob-door authentication. Raising `reconcile_max_concurrency`. A guest-agent update that skips a reboot.
