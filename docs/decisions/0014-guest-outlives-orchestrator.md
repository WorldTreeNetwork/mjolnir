# ADR 0014: A guest outlives an orchestrator restart

**Status:** Accepted 2026-10-20

Review-pair: `opus-arch-review` stalled at 300s (no verdict). Astra (`gpt-6-astra`) cautioned twice. The fences Astra named are in the classifier below. Astra's third review agreed. The tradeoff she named stands: an unresolved guest waits for an operator rather than a second VMM on the same disk.

## Decision

Cloud Hypervisor, virtiofsd, and the TAP for each guest run in a per-VM systemd scope under the sibling slice `mjolnir-vms.slice`. That slice is not part of `mjolnir.service`. `KillMode=control-group` on the Elixir service therefore does not reap guests. The BEAM does not own those processes as Erlang ports.

Detach is a third teardown outcome, beside stop and preserve-rootfs. Orchestrator shutdown detaches: it drops its handles and does not signal the scope. `VM.stop` still kills that scope. Preserve-rootfs still means the disk is kept when a boot fails. Detach is not preserve: the guest keeps running.

On startup, Cleanup classifies each VMM before it deletes sockets or TAPs, and before the async Reconcile task. The rootfs sweep already preserves a subvolume when the StateStore cannot be read. This classifier does the same for processes.

Checked in this order:

- The store cannot be read: touch nothing. Do not kill, adopt, delete a socket, or delete a TAP.
- The process is alive and the intent is `:stopped` or `:failed`: do not adopt and do not kill. Leave the scope, and do not delete its sockets or TAP. This wins over `restart_policy`. An operator stops it.
- The process is alive, the pidfile nonce matches the record, and `/proc/<pid>` starttime matches the starttime stored on the record, and the intent is `:running` or `restart_policy: :never`: adopt. Protect that guest's sockets, disk, and TAP from the rest of the sweep. A `:never` guest still has to pass the nonce and starttime checks.
- The process is alive but the nonce or the starttime does not match: do not adopt and do not start a replacement. Protect its sockets, disk, and TAP. Leave it unresolved.
- There is no record, and the store was readable: kill. That is a true orphan.
- The record says `:running` and the process is confirmed dead (pid gone, or starttime mismatch on a pid that now belongs to someone else): cold resume.
- Reconnect fails but the process is still alive: do not cold-boot. Leave the scope running, keep its sockets and TAP, and retry attach. A second VMM is not started on that disk.

Identity is a pidfile in a root-owned directory plus the same nonce and the `/proc` starttime written on the StateStore record at spawn. A cmdline that mentions the socket directory is not identity. PID reuse fails the starttime check. A nonce that does not match the record is not adopted, and it is not a license to boot another VMM on that disk.

`:attach` is a boot continue beside `:boot` and `:thaw`. It reopens the API socket and the vsock. It does not call `vm.boot`. It does not run the managed LUKS unlock again. The volume is already open. `extra_mounts` are stored on the running record so an adopted CI VM can name the virtiofsd processes it already has.

A `restart_policy: :never` guest that is still alive, and that passes the nonce and starttime checks, is adopted before Reconcile's finalize step. That exception does not cover a `:stopped` or `:failed` intent. Finalize runs only when that guest's process is confirmed dead. "Not in the registry" is not "dead" once the VMM can outlive the BEAM.

An Elixir-only deploy does not reboot guests. A guest-agent update still reboots the guests that must pick up the new binary, and the deploy path says so.

Cold boot remains the fallback for power loss and for a VMM that is confirmed dead. Attachment failure while the process is alive is not a cold boot.

## Probe (mjolnir-uepi.1)

Throwaway id `uepi-probe-stdio` on the hypervisor. A separate Elixir BEAM, not the production node (pid stayed `1164307`). No `systemctl restart`.

Closing the Erlang port that owns stdout, and halting that BEAM, left both `virtiofsd` and `cloud-hypervisor` alive. Pointing stdout and stderr at a log file did not change that: both still survived. Closing the pipe without a signal also left both alive. An explicit `SIGHUP` killed both (`virtiofsd` exit 1, `cloud-hypervisor` signal 1).

The probe is not "die on close". Log files are not a precondition for surviving the port close. They are still how these processes should log, because a later write to a dead pipe was not part of the probe. The production restart reaps guests by the service cgroup and by `Cleanup.sweep`, which is why the slice move is the survival claim, not the stdout pipe.

## Why not the alternatives

A higher resume concurrency still reboots every guest. Memory thaw restores RAM after tearing the source VMM down. These guests are already running. `KillMode=process` leaves the ports and the sweep in place, and it leaks VMMs when the BEAM is really gone.

## Out of scope

Blob-door authentication. Raising `reconcile_max_concurrency`. A guest-agent update that skips a reboot.
