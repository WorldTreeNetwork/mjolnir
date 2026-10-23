# vm-freeze

What is built. Folded from
[`add-vm-freeze-thaw`](../../changes/archive/2026-09-10-add-vm-freeze-thaw/proposal.md)
on 2026-09-10.

## Purpose

Operators park a running VM into a named memory snapshot
(`mj freeze` / `POST /api/vms/:id/freeze`) and restore the **same
VM id** (`mj thaw` / `POST /api/snapshots/:name/thaw`). The source
VMM and virtiofsd are torn down; `vm.snapshot` is terminal for
virtio-fs, so filesystem `mj snapshot create` stays filesystem-only.
The catalog reports `kind` (`filesystem` | `memory`). Spawn from a
memory snapshot is refused.

## Requirements

### Requirement: Freeze is a named one-way park
The system SHALL expose `POST /api/vms/:id/freeze` with body `{name}` that
captures filesystem and guest RAM as one named artifact, then tears down the
source VMM and virtiofsd. The source VM SHALL NOT keep serving. Filesystem
`POST /api/vms/:id/snapshots` SHALL remain unchanged.

#### Scenario: Operator parks a running VM
- GIVEN a running VM the caller owns
- WHEN `POST /api/vms/:id/freeze` with a new snapshot name
- THEN the response is 201 with snapshot metadata including `kind` of
  `memory` and `source_terminal` true
- AND the VM is no longer running
- AND `GET /api/snapshots/:name` reports `kind` `memory`

#### Scenario: Freeze says the VM stops
- GIVEN the CLI `mj freeze <id> <name>`
- WHEN freeze succeeds
- THEN the CLI states that the VM is parked (stopped) and names `mj thaw`
  as the restore

### Requirement: Thaw restores the same VM id
The system SHALL expose `POST /api/snapshots/:name/thaw` that restores a
memory snapshot into the `source_vm_id` recorded at freeze. If that id is
already live, the system SHALL refuse.

#### Scenario: Thaw brings the same VM back
- GIVEN a memory snapshot whose source VM is not running
- WHEN `POST /api/snapshots/:name/thaw`
- THEN a VM with the original id is running
- AND entropy has been reseeded before the VM is reachable (PTY, ticket,
  gateway)

#### Scenario: Thaw refuses a live id
- GIVEN a memory snapshot whose source VM id is already running
- WHEN thaw is requested
- THEN the response is 409

#### Scenario: Thaw refuses a filesystem snapshot
- GIVEN a filesystem-only snapshot
- WHEN thaw is requested
- THEN the response is 400 naming spawn-from-snapshot as the filesystem path

### Requirement: Spawn does not cold-boot a memory snapshot
`POST /api/vms` with `snapshot` set to a memory snapshot SHALL refuse rather
than clone the filesystem and cold-boot (which would drop guest RAM).

#### Scenario: spawn --snapshot on a freeze artifact
- GIVEN a memory snapshot name
- WHEN `POST /api/vms` with that snapshot
- THEN the response is 400 `memory_snapshot_requires_thaw`
- AND the body points at thaw

### Requirement: A VM keeps one memory snapshot
Each source VM SHALL have at most one retained memory snapshot after a
successful freeze. The previous memory snapshot SHALL stay on disk until the
replacement capture is complete, and SHALL be removed once that capture
succeeds. A freeze that fails before a complete capture SHALL leave the
previous memory snapshot in place. A same-name freeze SHALL write the new
image beside the current one and publish it under that name only after the
capture succeeds; a crash in that window SHALL still thaw under that name.
Filesystem snapshots SHALL NOT be removed by this rotation.

#### Scenario: The next freeze replaces the previous memory snapshot
- GIVEN VM `v` has a memory snapshot `old`
- WHEN freeze of `v` succeeds as `new`
- THEN `new` is a memory snapshot
- AND `old` is gone
- AND a filesystem snapshot of `v` is still present

#### Scenario: A failed freeze keeps the previous memory snapshot
- GIVEN VM `v` has a memory snapshot `old`
- WHEN freeze of `v` fails before a complete capture
- THEN `old` is still a memory snapshot

#### Scenario: Re-freeze of the same name replaces it
- GIVEN VM `v` has memory snapshot `park`
- WHEN freeze of `v` succeeds with name `park`
- THEN `park` is the new image
- AND the image captured before this freeze is gone

### Requirement: Snapshot catalog distinguishes kinds
`GET /api/snapshots` and `GET /api/snapshots/:name` SHALL include `kind`
of `filesystem` or `memory`. Kind is determined by whether memory artifacts
(`state.json` under `@snapshots/<name>.mem`) exist, not solely by a metadata
claim.

#### Scenario: list shows both kinds
- GIVEN one filesystem snapshot and one memory snapshot
- WHEN listing snapshots
- THEN each entry has `kind` set accordingly

### Requirement: Thaw steps wall time before reachability
A thaw SHALL make the guest wall clock agree with host time before the VM is reachable (PTY, ticket, gateway). The system SHALL NOT add the freeze duration to `CLOCK_MONOTONIC`. A clock step that fails SHALL fail the thaw and SHALL NOT publish the VM.

#### Scenario: Parked VM wakes on host time
- GIVEN a memory snapshot whose guest clock is more than an hour behind the host
- WHEN that snapshot is thawed
- THEN the guest wall clock matches host time before PTY, ticket, or gateway publish
- AND `CLOCK_MONOTONIC` has not jumped by the park duration

#### Scenario: Clock step failure stays unpublished
- GIVEN a thaw whose clock step fails
- WHEN the caller asks for a connection ticket
- THEN no ticket is issued
- AND the VM is not published on the gateway

### Requirement: Thaw health includes Iroh reachability
A thawed VM SHALL NOT be reported healthy, and SHALL NOT be reachable (PTY, ticket, gateway), until an Iroh reachability probe succeeds. A successful guest-agent vsock ping SHALL NOT satisfy that probe. The probe SHALL run only after entropy reseed and the wall-clock step have succeeded.

#### Scenario: Dead Iroh stays unhealthy
- GIVEN a thawed VM whose guest agent answers vsock ping
- AND whose Iroh node is not reachable
- WHEN the operator reads health
- THEN the VM is unhealthy
- AND no connection ticket is issued

#### Scenario: Probe success publishes
- GIVEN a thawed VM whose Iroh reachability probe succeeds after reseed and clock step
- WHEN the operator asks for a ticket
- THEN a ticket is issued
- AND health reports the VM healthy

### Requirement: Storage reports memory snapshots apart from CoW snapshots
`GET /api/storage` and `mj storage` SHALL report memory-snapshot usage as its own count, logical bytes, and exclusive bytes. That report SHALL NOT be only the `@snapshots` area total. A host with no memory snapshots SHALL report a count of zero. The system SHALL NOT add a second compression pass; on-disk size follows the btrfs mount compression.

#### Scenario: Frozen RAM is visible beside the snapshot area
- GIVEN one filesystem snapshot and one memory snapshot
- WHEN the operator runs `mj storage`
- THEN memory-snapshot count is 1
- AND the memory-snapshot byte count is separate from the `@snapshots` area

#### Scenario: No freezes
- GIVEN no `@snapshots/*.mem` directory
- WHEN `GET /api/storage` is called
- THEN the memory-snapshot count is 0
