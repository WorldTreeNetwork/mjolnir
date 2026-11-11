# aie-compute

What is built. Folded from
[`add-aie-host-sidecar`](../../changes/archive/2026-11-11-add-aie-host-sidecar/proposal.md)
and
[`add-aie-keyspace-claims`](../../changes/archive/2026-11-11-add-aie-keyspace-claims/proposal.md)
on 2026-11-11. Architecture
[`add-aie-compute`](../../changes/add-aie-compute/proposal.md) stays
inflight. ADR
[`0015`](../../../docs/decisions/0015-aie-compute-sidecar.md).

## Purpose

Host AIE sidecar on `:host_api_ip:7422`. Dedicated `mjolnir-aie`
user, BEAM admit on `aie-admit.sock`, occupancy flock, locator
`aie_url` in the guest map. Guests do not receive the NPU.
Capacity is a signed SecretStore offer leaf under the owner's
keyspace; spawn does not mint it.

## Requirements

### Requirement: AIE sidecar unit binds the overlay

The AIE sidecar SHALL run as user `mjolnir-aie` in group
`mjolnir-aie`, SHALL NOT run as root, and SHALL be able to open
`/dev/accel/accel0`. It SHALL bind `:host_api_ip` (default
`10.200.0.1`) port `:aie_compute_port` (default `7422`) and SHALL
NOT bind `0.0.0.0` or loopback. Guest TCP SHALL be INPUT. Install
SHALL ride `just deploy`. The process SHALL NOT be given
`/run/mjolnir/operator.sock`.

#### Scenario: Sidecar is not root

- GIVEN a running AIE sidecar
- WHEN an operator inspects its unit user
- THEN the process is not uid 0
- AND it can open `/dev/accel/accel0`

#### Scenario: Bind is overlay only

- GIVEN the sidecar is running
- WHEN `ss` is inspected
- THEN it listens on `10.200.0.1:7422`
- AND it does not listen on `0.0.0.0:7422`

### Requirement: BEAM admit socket is scoped

The orchestrator SHALL listen on `/run/mjolnir/aie-admit.sock`
mode `0660` owner root group `mjolnir-aie`. That listener SHALL
NOT mark connections as operator and SHALL expose only enqueue
and admission. After BEAM or listener restart the socket SHALL
be recreated with the same path, mode, owner, and group.
`/run/mjolnir/operator.sock` SHALL remain `0600` root.

#### Scenario: Non-root sidecar can enqueue and admit

- GIVEN the sidecar user in group `mjolnir-aie`
- WHEN it calls enqueue then admission for a valid proof
- THEN both calls succeed (subject to policy and occupancy)

#### Scenario: Unrelated local user cannot admit

- GIVEN the admit socket
- WHEN a uid not in group `mjolnir-aie` connects
- THEN the connect is refused

#### Scenario: Sidecar identity cannot use operator VM routes

- GIVEN the sidecar OS credential
- WHEN it calls VM spawn, exec, kill, or snapshot
- THEN the call is refused

### Requirement: Pending admit authorizes one live load

The BEAM SHALL own the pending table. Enqueue SHALL consume the
nonce once and return `pending_id`. Admission SHALL name
`pending_id` and occupancy `attempt_id`. Load SHALL require a
live success on the current attempt (lock held, deadline live,
no prior load). Cached `dispatched` after abandon SHALL NOT
authorize a load. Restart SHALL invalidate pending ids.

#### Scenario: Lost reply on a live attempt may load once

- GIVEN a dispatched `(pending_id, attempt_id)` whose reply was
  lost while the lock is still held within the deadline
- WHEN the sidecar retries that pair
- THEN the first load MAY start
- AND a second load does not start

#### Scenario: Abandoned attempt cannot load

- GIVEN deadline expiry or lock release
- WHEN a late success or retry of that `pending_id` arrives
- THEN the sidecar does not load

### Requirement: Occupancy flock serializes catalog jobs

The sidecar SHALL try-lock the IRON Lab flock, admit under a
deadline, then load a host-catalog design id or release. It
SHALL NOT load a guest-authored xclbin. It SHALL kill the
worker at the leaf wall time and release only after quiescence.

#### Scenario: Second run does not clobber

- GIVEN a run holding the occupancy lock
- WHEN a second execute arrives
- THEN the first program stays loaded until it finishes

#### Scenario: Guest xclbin is refused

- GIVEN an xclbin that is not a host-catalog design id
- WHEN execute is presented
- THEN admit refuses
- AND the sidecar does not load it

### Requirement: Capacity is a signed keyspace claim

An offer SHALL be a signed SecretStore record under the owner's
IdentiKey fingerprint (`owner_fp`). Canonical execute resource SHALL
be `{owner_fp, offer_id}` plus `incarnation` (Blake3 of the
canonical signed leaf). `VM.spawn/1` SHALL NOT create that record.
A missing, unsigned, wrong-fingerprint, or other-being VM offer
SHALL not authorize execute. Publish and mint SHALL require the
named VM's IdentiKey to equal the keyspace owner **and** that VM
id to be on this host's operator-held allowlist of offering VMs.
Equal local `offer_id` values in different owner keyspaces SHALL
be distinct rights. Mint SHALL copy incarnation from the current
verified leaf. The leaf SHALL carry a strictly increasing sequence.
A tombstone SHALL be retained as a floor. Put of a leaf at or below
that floor, including re-put of retired bytes, SHALL be refused.
v1 SHALL revoke by whole-offer replacement.

#### Scenario: Spawn does not mint capacity

- GIVEN a VM spawned with no prior offer record
- WHEN spawn returns
- THEN no AIE offer leaf exists in the owner's keyspace for that VM

#### Scenario: Unsigned offer is refused

- GIVEN bytes at the offer key that do not verify as the owner's
  signed envelope
- WHEN execute names that offer
- THEN execute is refused

#### Scenario: Cross-keyspace id collision does not share rights

- GIVEN owner A and owner B both published local id `npu`
- WHEN a token for `A/npu` is presented against `B/npu`
- THEN execute is refused

#### Scenario: Unrelated VM in a signed leaf is refused

- GIVEN an owner-signed offer that names a VM whose IdentiKey is
  not that owner
- WHEN execute or mint is attempted for that offer
- THEN it is refused

#### Scenario: Guest not on the allowlist cannot offer

- GIVEN a running VM whose IdentiKey equals its keyspace owner
  but whose VM id is not on the host allowlist
- WHEN it publishes or mints an AIE offer
- THEN publish and mint are refused

#### Scenario: Re-put of retired bytes is refused

- GIVEN a tombstone whose floor sequence is N and the exact
  signed bytes of a retired leaf at sequence ≤ N
- WHEN those bytes are put again at the same key
- THEN the put is refused
- AND tokens for that retired incarnation stay refused
