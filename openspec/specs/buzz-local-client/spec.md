# buzz-local-client

What is built. Folded from
[`add-buzz-local-client`](../../changes/archive/2026-08-16-add-buzz-local-client/proposal.md)
on 2026-08-16, and from `mjolnir-1pe` on 2026-08-17. Decisions that
are not yet code live in
[`docs/decisions/0002-buzz-local-client-fabric.md`](../../../docs/decisions/0002-buzz-local-client-fabric.md)
and `openspec/changes/add-buzz-local-runtime/`.

## Purpose

Request-path thaws are fail-closed. Buzz bodies with `restart_policy:
never` cannot enter `DormantRegistry`. Guests stay off the Erlang
cluster. The host Postgres sidecar is a catalog, not a tenant hotel.
The agent nsec is an opaque SecretStore blob, not a field on the VM
record.

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
indexes as schemas in the existing host database `mjolnir`. It SHALL
NOT hold a Buzz community event log. A declared tenant database
(capability `host-postgres`) MAY live in the same Postgres process as
a separate `CREATE DATABASE`. Guests SHALL have no path to the
sidecar unless their spawn is given that tenant’s connect secret.
Default guests SHALL NOT reach the Unix socket or the tenant TCP
listener.

#### Scenario: Unprovisioned guest cannot reach the sidecar

- GIVEN a running guest with no tenant-database secret
- WHEN the guest attempts TCP, vsock, or a Unix-socket connect to host Postgres
- THEN the connection is not possible by default configuration

#### Scenario: Buzz events stay off the sidecar

- GIVEN the host sidecar
- WHEN Buzz community events are stored
- THEN they are not written to the sidecar

### Requirement: Secrets stay off the host artifacts

The agent `nsec` SHALL be treated as an opaque string (no curve math).
`Mjolnir.Identity` SHALL store it in `SecretStore` under
`_opaque/vms/<vm_id>/` and SHALL inject it over vsock
(`inject_identity`) as `BUZZ_PRIVATE_KEY` plus `BUZZ_RELAY_URL`.
The nsec SHALL NOT be kept on the VM struct. `build_running_record/1`,
list/info API bodies, and `Inspect` of a VM SHALL NOT contain it.
Host-side `Identity.put/2` and inject logs SHALL NOT print the value.

A guest that prints its own env is out of scope for this host
invariant. Writing `/run/mjolnir/buzz.env` inside the guest requires
the `inject_identity` guest agent to be deployed.

#### Scenario: Negative scan of host artifacts

- GIVEN identity stored for a VM
- WHEN the StateStore running record, list/info API bodies, `Inspect`
  of the VM, and logs from `Identity.put/2` are searched for the nsec
- THEN there are no matches
