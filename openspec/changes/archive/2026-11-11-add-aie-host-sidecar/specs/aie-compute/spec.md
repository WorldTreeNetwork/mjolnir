## ADDED Requirements

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
