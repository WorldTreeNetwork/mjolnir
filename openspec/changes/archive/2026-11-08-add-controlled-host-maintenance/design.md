# Controlled host maintenance

The local Python CLI talks to a bundled, standard-library remote helper over
BatchMode SSH. Requests use stdin JSON; dynamic data is never interpolated as
shell syntax. Guest commands use the existing root-only Unix operator socket,
including while the public gateway is stopped. There is no TCP auth fallback.

A private local run directory freezes configuration, host/machine/boot identity,
VM IDs, known identities, guest boots, active services and HTTP baseline. A private
remote journal owns an exclusive maintenance lease and records stop/request intent
before effects. A different run cannot steal it; an ambiguous host action is never
automatically issued again. An interrupted preparation can be resumed or undone.
An advisory host-file lock is held for the entire mutating remote operation, so
even two clients with the same run token cannot execute maintenance concurrently.
Journal/lease files and replacements are fsynced, including their parent directory.

Only registry app units and operator-classified units are stopped. Unknown active
units and non-restarting/missing running-intent guests fail planning. Protected
controller, guest-agent, SSH and system units cannot be stopped. Database units
are a separate phase: application writers stop, configured backup hooks create
fresh private exports, dependency services stop, guest filesystems sync, and VM
roots receive read-only recovery snapshots. Existing enablement is unchanged.

Backup hooks are trusted operator argv arrays and suppress output. Export paths
must exist freshly after their hook. A bounded archive combines configured host
configuration, selected guest data from snapshots and hook exports. The client
copies it outside the host, checks SHA-256 and archive readability, and only then
records preparation complete. This is not proof of database restorability or of
complete discovery of arbitrary application data. Archives and journals stay out
of git; no seed/password/environment contents enter normal logs.

Preparation errors attempt to resume this run's previously active units. Journals
survive failed cleanup, and an explicit resume remains available. Resume never
starts a unit that was inactive at baseline or unrecorded by the run. No enablement
edits, persistent service holds, VM replacement or database creation are needed.
Before any resume the journal durably leaves the prepared state. Resume is limited
to the original host boot and original guest boot identities, restores dependencies
before writers and verifies activation. A stop recorded only as requested is
uncertain: if still active it needs no start; if inactive it requires manual
reconciliation and is never automatically claimed as an owned completed stop.
Successful resume is terminal for that preparation; reboot requires a new plan,
new quiescence and fresh snapshots/exports. Partial resume remains a failure.

Before power actions the script rechecks host identity, the unchanged VM set and
policies, completed quiescence, target GRUB selection, backup digest receipt and
lease ownership. A read-only plan cannot reboot; every mutating entry point needs
the execution flag. Shutdown only requests poweroff; provider power-on is external.
Immediately before power the tool rechecks every planned stopped unit is inactive;
timer/socket/dependency reactivation invalidates preparation. All mutating phases
hold the host lock, and action-requested is fsynced before dispatch. After an
ambiguous request only verification is supported, never an automatic retry or
replaying the old stop journal against new guest incarnations.

Plan refuses active CI-tagged VMs before guest exec because that API renews CI
leases. It requires running-intent guests with restart_policy=always and refuses
unknown/unclassified workloads. Service autostart is the existing systemd contract;
the script does not add persistent holds or invent new startup dependencies.

Reboot recovery requires a different host boot ID, expected kernel, same VM IDs,
new guest boot IDs, preserved known identities, mounted managed secrets, previously
running services and configured readiness probes. Healthy HTTP baselines must
remain healthy; pre-existing failures remain explicit. Failures produce a nonzero
exit and retained evidence, never a clean result or another automatic reboot.

Tests use an injected fake transport and command runner; they never contact SSH
or production. Required negative fixtures include missing execution authority,
wrong host, stale/drifting inventory, failed/old backups, checksum mismatch,
unknown units, partial recovery, lost identity, new HTTP failure, interrupted
preparation and ambiguous reboot acknowledgement.
