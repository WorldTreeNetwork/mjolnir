## ADDED Requirements

### Requirement: Admit before thaw

A message that would activate a dormant VM or be delivered into a
Buzz-managed VM SHALL pass an admission facade before
`deliver_message` or `DormantRegistry` restore runs. Admission SHALL
be decided on the host, without executing guest code. A denied or
dropped message SHALL leave the VM’s run state unchanged.

#### Scenario: Junk does not thaw

- GIVEN a Buzz-managed VM that is dormant or `:stopped` after an
  intentional harness exit
- WHEN an unadmitted payload arrives on `POST /api/vms/:id/messages`
- THEN the VM is not restored, not spawned, and not marked running

#### Scenario: Admitted control still thaws

- GIVEN a dormant VM and an admitted control payload (provider drain,
  operator poke, or a signed IdentiKey envelope for that actor)
- WHEN the facade accepts it
- THEN delivery follows the existing vsock / restore path

### Requirement: Mailbox versus Nostr

The host OTP mailbox (VM GenServer + `deliver_message`) SHALL carry
body-control and admission outcomes. Buzz chat, presence kinds, git,
workflows, and canvases SHALL remain Nostr events on the relay. The
host SHALL NOT persist kind 9 (or other Buzz event kinds) as a
substitute event log.

#### Scenario: A mention is not a mailbox payload

- GIVEN a running Buzz-managed agent VM
- WHEN a human posts a channel mention in the Buzz desktop
- THEN the desktop and `buzz-acp` exchange that event with the relay
  over Nostr
- AND the host mailbox is not required for the mention bytes to land

### Requirement: Guests stay off the Erlang cluster

Guest VMs SHALL communicate with the host over vsock, Iroh, and the
HTTP gateway. They SHALL NOT join Distributed Erlang or expose EPMD.

#### Scenario: No cookie path into the guest

- GIVEN a running guest
- WHEN an operator inspects the guest’s listening ports and process
  list
- THEN there is no Erlang distribution listener accepting the host
  cookie

### Requirement: Admission lives in identikey-protocol

The admission facade SHALL be a permissively licensed protocol
artifact (Apache-2.0 OR BSD-2-Clause-Patent) in `identikey-protocol`,
embeddable from Mjolnir without taking the AGPL of `identikey-core`.
Mjolnir SHALL NOT become the only copy of admission rules.

#### Scenario: A second embedder can link the crate

- GIVEN the admit crate published from `identikey-protocol`
- WHEN a gateway plugin or CDN origin adapter depends on it
- THEN it does not pull `identikey-core` or an AGPL obligation

### Requirement: Host sidecar is control-plane only

The OTP-managed Postgres sidecar SHALL store derived host-service
indexes (Sites, and later admit/forge catalogs). It SHALL NOT hold a
tenant app database, a Buzz community event log, or a database whose
owner is a guest. Guests SHALL have no network path to the sidecar
socket.

#### Scenario: Buzz relay data is in the relay VM

- GIVEN a self-hosted Buzz relay running as a Mjolnir VM
- WHEN that community’s events are queried
- THEN they are served from Postgres (or successor) **inside that
  VM’s** filesystem
- AND a snapshot of the VM includes the event log

#### Scenario: Guest cannot reach the sidecar

- GIVEN a running guest and the host sidecar listening on its Unix
  socket
- WHEN the guest attempts a TCP or vsock connection to host Postgres
- THEN the connection is not possible by default configuration

### Requirement: Dev image is the test image

Human development VMs and CI VMs SHALL clone the same base
(`@base/dev`). That image SHALL include the guest agent and a
single-process in-guest Postgres-compatible store (PGlite) for
scratch. Stateful production workloads that need concurrent writers
SHALL run real Postgres inside their own VM, not on the host sidecar.

#### Scenario: Spawn a dev box

- GIVEN `@base/dev` exists on the host
- WHEN an operator runs `mj spawn` against that base (or the API
  equivalent)
- THEN the VM boots with a working guest agent and can run the
  project’s tests without a second orchestrator

### Requirement: Provider-deployed identity on our relay

A self-hosted Buzz relay used as the local-client target SHALL accept
the provider-deployed identity class (desktop-minted key plus NIP-OA
`auth_tag`). The “plain member, no auth_tag” workaround SHALL NOT be
the default join path.

#### Scenario: Deployed agent is a relay member

- GIVEN our relay and a `deploy` that presents `private_key_nsec` and
  `auth_tag`
- WHEN the harness authenticates
- THEN the relay does not refuse with `restricted: not a relay member`

### Requirement: Intentional Buzz exit stays down

A VM spawned for a Buzz body SHALL use `restart_policy: never`. An
intentional harness exit SHALL finalize the record as stopped. An
unadmitted subsequent message SHALL NOT resume it.

#### Scenario: Shutdown then mention

- GIVEN a Buzz-managed VM whose harness exited 0 / `exited`
- WHEN a channel mention arrives and admission does not grant a wake
- THEN the VM remains stopped
- AND Reconcile does not rehydrate it

### Requirement: Secrets stay off the host artifacts

The agent `nsec` SHALL be treated as an opaque string, stored in
SecretStore, and injected over vsock. It SHALL NOT appear in the VM
record, API responses, host logs, or the syslog stream.

#### Scenario: Negative scan

- GIVEN a successful deploy of a Buzz body
- WHEN the VM record, list/info API bodies, journald lines, and
  syslog router output are searched for the nsec
- THEN there are no matches
