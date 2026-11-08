## ADDED Requirements

### Requirement: Explicit, bound maintenance authority
The operator tool SHALL offer read-only planning and SHALL require an explicit
execution flag for preparation, resume and host power actions. A private run
journal SHALL bind the target, machine, boot, configuration and VM baseline. A
different run SHALL NOT steal an active remote lease. Snapshot/backup/journal
paths SHALL be private and SHALL NOT overwrite unrelated artifacts.
The remote operation lock SHALL serialize even same-run clients and SHALL cover
the full mutating operation. Journal/lease transitions SHALL be atomic and fsynced.

#### Scenario: Read-only or mismatched invocation
- GIVEN a plan or a journal for a different host/configuration
- WHEN execution authority is absent or the binding does not match
- THEN no service stop, snapshot, backup hook or host power command is issued.

### Requirement: Quiescence preserves guests and original data
Preparation SHALL stop only classified application/dependency units and SHALL
record each stop before dispatch. Unknown active units SHALL block preparation.
Controller/agent/SSH units, VM running intent, restart policy and service enablement
SHALL remain unchanged. No VM kill/spawn/delete or database initialization is allowed.
Preparation failures SHALL attempt to resume only previously active units stopped
by this run and SHALL preserve evidence when that recovery cannot complete.
Stop completion SHALL be recorded separately from stop intent. Resume SHALL
invalidate power readiness durably before effects, require unchanged host/guest
boot identities, restore dependencies before writers and verify restoration.
Uncertain inactive stops SHALL NOT be automatically attributed to this run.
Resumed preparation SHALL NOT be reused for a power action.

#### Scenario: Preparation is interrupted
- GIVEN recorded stop intents and a failed backup or SSH connection
- WHEN the operator resumes or retries preparation
- THEN no unrelated/inactive service is started and no destructive VM API is used.

### Requirement: Verified recovery material precedes power actions
The tool SHALL require successful fresh configured backup exports, read-only VM
snapshots, an off-host archive whose checksum and readability were verified, and
valid target/fallback kernel, initramfs, GRUB and SSH startup checks before issuing
a normal reboot or poweroff. Changed VM membership or restart policy SHALL refuse
the host action. An ambiguous acknowledgement SHALL NOT automatically be retried.
Every planned stopped unit SHALL still be inactive immediately before dispatch;
otherwise preparation is invalid. Action intent SHALL be durable before dispatch.

#### Scenario: Backup is missing, stale, corrupt or only locally acknowledged
- GIVEN a successful stop phase but incomplete backup evidence
- WHEN reboot or shutdown is requested
- THEN the host power command is not dispatched and the run reports failure.

### Requirement: Actual recovery decides success
Verification SHALL require a new host boot with the expected kernel, the original
VM set with new guest boot IDs and preserved known identities, managed-secret
mounts, previously running services, configured readiness probes and no new healthy
HTTP baseline regressions. Unknown/unreachable/partial results SHALL fail verification.
Existing failures SHALL remain identified, not be counted as new or clean.

#### Scenario: Host returns but guests or databases do not
- GIVEN a new SSH connection and an incomplete recovery
- WHEN verification reaches its deadline
- THEN the result is nonzero, evidence remains and no second reboot is issued.
