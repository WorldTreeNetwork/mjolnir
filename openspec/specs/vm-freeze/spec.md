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

### Requirement: Snapshot catalog distinguishes kinds
`GET /api/snapshots` and `GET /api/snapshots/:name` SHALL include `kind`
of `filesystem` or `memory`. Kind is determined by whether memory artifacts
(`state.json` under `@snapshots/<name>.mem`) exist, not solely by a metadata
claim.

#### Scenario: list shows both kinds
- GIVEN one filesystem snapshot and one memory snapshot
- WHEN listing snapshots
- THEN each entry has `kind` set accordingly
