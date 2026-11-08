# add-controlled-host-maintenance

> **ACTIVE BUILD**

## Why
The November 8 controlled reboot required a manual inventory, guest quiescence,
database backups, BTRFS snapshots, off-host checksum verification and recovery
comparison. Those steps need a repeatable operator command that refuses unsafe
or incomplete inputs and survives a lost SSH connection.

## What
- Add a standard-library Python operator script: plan, prepare, reboot, shutdown,
  verify and resume. Mutating operations require `--execute`.
- Use SSH and the root-only operator socket, preserving VM identity, running
  intent, restart policies, existing service enablement and original data.
- Journal actions before dispatch, verify off-host backup bytes before host
  actions, and fail recovery on new baseline regressions.

## Impact
- Capabilities: ADDED `host-maintenance`.
- ADRs: none; existing SSH/operator-socket and guest-lifetime contracts are reused.

## User journey & surfaces
No new UI because operators use the repository script and a private run directory.
Plan is read-only. Prepare pauses only explicitly classified services. Reboot and
shutdown refuse unverified preparation. Verify waits for actual recovery. Resume
starts only previously active units whose stops this run recorded.

## Preparation and authority
User requested a script for the completed controlled shutdown/reboot. That grants
implementation of this scope, not another production host action. Prepared against
60d9d85, `guest-lifetime`, the exec endpoint and existing backup scripts, plus the
private November 8 reboot evidence. Standalone Python avoids the unrelated Elixir
compiler problem. Existing untracked groups are outside the write set.

## Out of scope
- Another production shutdown/reboot, control-plane deployment or OS upgrade.
- Destructive VM lifecycle APIs, database initialization or automated data restore.
- Universal database discovery, arbitrary bootloaders, provider power-on, or a full
  off-site VM-image disaster-recovery system. Backup/probe coverage is explicit.
