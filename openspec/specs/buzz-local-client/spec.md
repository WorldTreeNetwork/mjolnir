# buzz-local-client

What is built. Folded from
[`add-buzz-local-client`](../../changes/archive/2026-08-16-add-buzz-local-client/proposal.md)
on 2026-08-16. Decisions that are not yet code live in
[`docs/decisions/0002-buzz-local-client-fabric.md`](../../../docs/decisions/0002-buzz-local-client-fabric.md)
and `openspec/changes/add-buzz-local-runtime/`.

## Purpose

Request-path thaws are fail-closed. Buzz bodies with `restart_policy:
never` cannot enter `DormantRegistry`. Guests stay off the Erlang
cluster. The host Postgres sidecar is a catalog, not a tenant hotel.

## Requirements

### Requirement: Proxies admit; trusted deliver is attested

`Mjolnir.Admit.thaw_allowed?/2` SHALL decide whether a payload may
thaw a dormant VM. `Mjolnir.VM.deliver_message/3` and
`Mjolnir.DormantRegistry.queue_message/3` SHALL refuse
(`:admission_denied`) and SHALL NOT write `pending_messages` or start
restore when that check fails. v1 is a shape check: an attestation
map with matching `vm_id` and a non-negative integer `epoch`. Missing
or mismatched attestation is deny.

The request facade is not the only resurrection path. Operator
revive, Health, and Reconcile under `restart_policy: always` do not
go through `Admit`.

#### Scenario: Junk does not thaw

- GIVEN a dormant VM
- WHEN `deliver_message/3` is called with a payload that has no valid
  attestation
- THEN the result is `{:error, :admission_denied}`
- AND `pending_messages` is unchanged
- AND the entry stays `:dormant`

#### Scenario: Persist generation is not an epoch

- GIVEN `StateStore` persist `generation` has bumped with no restore
- WHEN `Admit` checks an attestation
- THEN it does not compare against that persist counter

### Requirement: Intentional never-policy exit stays down

`Mjolnir.Admit.dormancy_reason/1` SHALL return
`{:error, :never_prevents_dormancy}` when `restart_policy` is
`:never` (after `:secrets_prevent_dormancy`). `handle_done` /
`signal_done` SHALL refuse and SHALL NOT register
`DormantRegistry`. Reconcile SHALL finalize a stranded `:never`
record rather than resume it, unless owner revive is authorized.

#### Scenario: signal_done is refused on never

- GIVEN a VM struct with `restart_policy: :never`
- WHEN `Admit.dormancy_reason/1` runs
- THEN the error is `:never_prevents_dormancy`

### Requirement: Guests stay off the Erlang cluster

Guest VMs SHALL communicate with the host over vsock, Iroh, and the
HTTP gateway. They SHALL NOT join Distributed Erlang or expose EPMD.

#### Scenario: No cookie path into the guest

- GIVEN a running guest
- WHEN an operator inspects listening ports and processes
- THEN there is no Erlang distribution listener accepting the host
  cookie

### Requirement: Host sidecar is control-plane only

The OTP-managed Postgres sidecar SHALL store derived host-service
indexes as schemas in the existing host database. It SHALL NOT hold a
tenant app database or a Buzz community event log. Guests SHALL have
no network path to the sidecar socket.

#### Scenario: Guest cannot reach the sidecar

- GIVEN a running guest and the sidecar on its Unix socket
- WHEN the guest attempts TCP or vsock to host Postgres
- THEN the connection is not possible by default configuration
