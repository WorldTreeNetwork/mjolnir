> **ADVISE:** accept
> **READER:** gpt-6-astra / independent collaboration reader
> **SPAWN:** /root/maintenance_safety_review

Re-reviewed the revised proposal, ADDED host-maintenance specification, design and
tasks against the existing guest-lifetime contract. This is a contract review,
not evidence of implementation correctness or authorization for live maintenance.

## Independent concerns

1. Bind mutations to machine, host boot, configuration and guest identities.
2. A successful preparation must not survive a later resumption of writers.
3. Stop intent and confirmed owned stop are different states.
4. Ambiguous power dispatch must never be repeated automatically.
5. Lease ownership must remain exclusive through concurrency and disconnects.
6. Export bytes must be verified outside the host before any power action.
7. Running guests with non-restarting policies need refusal, not policy edits.
8. Unknown recovery observations must fail closed.
9. Service activation and startup order matter even without enablement edits.
10. Prefer explicit bounded recovery coverage over a general backup framework.

## Initial findings, now resolved in the contract

**1. Invalidate readiness before resumption.** The design allows explicit resume
after successful preparation but does not say that it revokes the backup receipt
as authority for a subsequent power action. Before any resume or rollback starts a
unit, durably clear power readiness. Require a fresh preparation afterward.
Immediately before dispatch, re-read every quiesced unit and reject any active or
unknown state; automatic timer/socket/dependency activation can restart writers
without any enablement edit. Refuse unsupported activation behavior rather than
introducing persistent holds. Tests should cover prepare → resume → reboot,
partial rollback and an automatically restarted writer.

**2. Specify atomic ownership and durable transitions.** A lease excluding a
different run does not exclude two concurrent processes operating on the same
run. Acquire an atomic host-wide operation lock for mutations, including same-run
clients. Persist and fsync intent before dispatch and atomically replace durable
journal state. Refuse a busy operation and never silently steal stale ownership.
Record power intent before dispatch so a lost response or local process crash
cannot reset it to retryable. Test concurrent same-run dispatch and interruption
between intent persistence and acknowledgement.

**3. Bound stop ownership to the guest incarnation.** Resume and repeated prepare
must validate host/guest boot identities and baseline bindings before applying
old stop records. Recovery after host reboot observes the new incarnations; it
must not replay pre-reboot service stops or starts. Distinguish intent, confirmed
stop and unknown dispatch. Reconcile unknown dispatch using fresh unit state;
never claim an unrelated or baseline-inactive unit. Test guest reboot during
preparation, host reboot before resume and SSH loss during stop.

**4. Restore dependencies before writers and verify restoration.** The contract
does not define resume ordering or success. Start this run's previously active
dependency units before its application writers, check successful activation,
and retain a nonzero incomplete-recovery result if any restoration is unknown or
fails. Do not release the journal/lease as clean merely because start commands
were attempted. Test failure in dependency restoration.

The bounded scope, no persistent guest holds, explicit execution authority,
off-host byte verification, non-restarting-guest refusal and baseline-relative
recovery are appropriate. These corrections tighten the existing workflow and
do not call for additional lifecycle APIs or a general maintenance framework.

## Revised contract verdict

The current design and ADDED specification explicitly address all four findings:
durable readiness invalidation with fresh preparation after resume; whole-operation
same-run serialization and fsynced transitions; original host/guest boot binding
and conservative uncertain-stop reconciliation; dependency-first verified resume.
They also pin last-moment inactive-unit checks and durable non-retryable power
intent. The design refuses CI-tagged guests before guest exec to avoid lease
renewal during the read-only plan.

Accept this bounded contract for implementation. This does not approve a live
reboot or establish that an implementation meets it. The parent owns task changes;
this reader's write set is this review only. Implementation review remains pending.

## First implementation review

Reviewed `scripts/controlled_reboot.py` and `scripts/maintenance_host.py` without
executing host operations. The contract remains accepted, but the implementation
needs these bounded corrections before acceptance:

1. `Host.quiescent` checks only recorded stops. A newly started, unclassified
   writer is invisible during exports, snapshots and the final power gate.
   Inspect current guest running-service sets and reject new running units
   relative to the baseline minus owned stops. Cover a new service appearing
   after preparation in an offline test.
2. `Host.plan` checks boot enablement for applications only. A running but
   disabled database can pass preparation and remain down after reboot. Require
   dependency startup evidence too; refuse unsupported activation models rather
   than adding holds or modifying enablement.
3. `Host.stop` does not compare its current observation with the planned unit
   observation or recheck that guest's boot before stopping it. The initial
   all-guest identity sweep can precede this mutation by minutes. Bind each stop
   to its baseline guest boot and activation immediately before dispatch, and
   include boot identity in quiescence checks. Test a guest reboot between the
   initial sweep and its stop.
4. `check_recovery` permits a current unknown/unreachable HTTP result when the
   baseline was already failing or unknown. Require a known current result for
   every configured URL; preserve known baseline failures as such without
   labeling them new regressions. Test a baseline 500 followed by unreachable.

The remote whole-operation lock, journal-before-power, no automatic retry,
readiness invalidation and conservative uncertain-stop recovery are present.
No code edits or live operations were performed by this reader.

## Revised implementation review

All four first-pass implementation findings are resolved in the current source.
The read-only host re-derivation also prevents edited client classifications from
silently omitting a writer. Reviewed the operator runbook and offline fixtures;
independently ran `python3 -m unittest discover -s scripts -p test_controlled_reboot.py`:
44 tests passed. No SSH or live operations were used.

One correction remains in the added PostgreSQL autostart exception:
`Host.dependencies_enabled` currently accepts every non-enabled state when the
instance name, enabled umbrella and `start.conf=auto` match. A currently active
but masked instance therefore passes despite not being startable after reboot.
Restrict this exception to the expected `enabled-runtime` state and test refusal
of masked/unknown states. This is a bounded validation correction, not a request
to manage systemd enablement.

## Final implementation verdict

Accept the current bounded implementation. The PostgreSQL exception now requires
`enabled-runtime` before checking the enabled umbrella and persistent auto-start
configuration; masked, disabled and unknown states fail before any probe. Its
new negative fixture covers those states. Independently reran the complete
offline suite: **45 tests passed**.

All findings from this review are resolved. Reviewed source, offline tests and
runbook support the accepted contract. This verdict does not claim a live
maintenance rehearsal, complete backup coverage or proven database restorability,
and does not authorize another production prepare, shutdown or reboot. The
separate read-only production plan remains the conductor's integration check.

## Final delta confirmation

Reviewed the subsequent bounded concurrent plan reads (four workers), mount-scoped
BTRFS identity listing, longer plan transport deadline, capacity refusal before
stops, frozen-configuration CLI enforcement, fresh guest export-directory guard
and bounded private subprocess-output capture. No blocking safety regression
found; acceptance remains in effect. Independently reran the offline suite:
**50 tests passed**.

The conductor reports a successful read-only production plan covering 52 VMs,
42 writer units and 3 dependencies, with unchanged host boot/service state and no
active maintenance lease. This production result is attributed to the conductor;
this reviewer made no live calls. It validates planning integration, not execution
of prepare, backup restoration or host power actions.

Subsequent export-budget hardening also reviewed: declared exports receive a
per-file write limit derived from the logical budget; configuration rejects a
budget too small to express that limit; guest shell limits conservatively handle
512/1024-byte units; host/data capacity checks include export headroom. The
runbook correctly treats hooks as trusted privileged code rather than a sandbox.
Acceptance remains unchanged. Final independent offline rerun: **50 tests passed**;
no live calls were made.

Reviewed the final client power gate: remote phase/configuration/receipt checks
precede dispatch, and the local off-host archive must still exist with matching
size and checksum. Backup loss refuses power and uses the existing conservative
resume path. Already-recorded remote power intent is adopted only for verification;
resumed and non-prepared states cannot authorize dispatch. The host-side lock and
phase guard still enforce refusal if remote state changes after the client read.
Acceptance remains in effect. Independent offline rerun: **53 tests passed**,
including deleted/corrupt local backup, remote resume and another-client power
intent. No live calls were made.
