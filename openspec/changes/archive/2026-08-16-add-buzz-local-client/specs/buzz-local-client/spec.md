## ADDED Requirements

### Requirement: Protocol facade (Nostr, later Matrix)

External chat protocols SHALL enter the host through an emulation
layer that translates them into the internal OTP message-passing
architecture (mailboxes, broadcast, 0MQ-shaped patterns). When an
internal message is delivered into a Buzz body, the last hop SHALL
translate it back into a conformant Nostr event for `buzz-acp`. The
host SHALL NOT persist Buzz event kinds as a substitute event log;
the relay remains the log. A later Matrix (or other) ingress SHALL
use the same internal architecture, not a second thaw path.

#### Scenario: Running body, mention stays on Nostr

- GIVEN a running Buzz-managed agent VM whose harness is connected to
  the relay
- WHEN a human posts a channel mention in the Buzz desktop
- THEN the desktop and `buzz-acp` exchange that event with the relay
  over Nostr
- AND the host mailbox is not required for those bytes to land

#### Scenario: Dormant body, Nostr becomes an internal wake

- GIVEN a dormant Buzz-managed VM
- WHEN a mention (or emulated Nostr event) arrives at the host ingress
- THEN the facade translates it to an internal message
- AND a proxy decides whether that message is an admitted wake
- AND if delivered, the last hop presents a conformant Nostr event to
  the guest harness

### Requirement: Wake producer is the protocol ingress

For Buzz, the producer of a wake SHALL be incoming traffic on the
external message queue in use — first Nostr, later also Matrix —
after translation by the protocol facade. The producer SHALL NOT be
the guest, Reconcile, or an implicit desktop-only side channel.

#### Scenario: Named producer

- GIVEN a dormant Buzz body and a mention on the relay
- WHEN a wake occurs
- THEN the host Nostr (or later Matrix) ingress produced the internal
  message that admission considered
- AND no other unnamed component is required for that production

### Requirement: Proxies admit; trusted deliver is attested

Untrusted ingress (HTTP, vsock, MCP, CLI, protocol facade) SHALL hit
an admission proxy before any restore. The proxy SHALL authorize,
fail closed if it cannot decide, and on accept stamp a signed
attestation. `Mjolnir.VM.deliver_message/3` (and
`DormantRegistry.queue_message/3`) SHALL accept a thaw only when that
attestation is present and valid for this VM and its **lifecycle
epoch**. Lifecycle epoch SHALL NOT be `StateStore`'s persist
`generation` (bumped on every heal and metadata merge). It SHALL
change when the body is created, restored from dormant, or
owner-started. A denied or dropped message SHALL NOT be queued and SHALL
leave run state unchanged. Admission SHALL run before any
`pending_messages` write and on the restore-retry path.

The facade is the common path for request-based services. It SHALL
NOT be specified as the only resurrection path.

#### Scenario: Junk does not thaw

- GIVEN a Buzz-managed VM that is dormant
- WHEN an unattested payload arrives on any caller of
  `deliver_message/3` (HTTP `/messages`, vsock, MCP, CLI)
- THEN the VM is not restored, not spawned, and not marked running
- AND the payload is not stored in `pending_messages`

#### Scenario: Persist generation is not an epoch

- GIVEN a dormant VM whose StateStore `generation` has bumped from a
  host-side metadata merge with no restore
- WHEN an attestation bound to the prior persist generation is checked
- THEN that mismatch alone SHALL NOT be the epoch check
- AND the epoch is still the last create / restore / owner-start

#### Scenario: Proxy-attested request may thaw

- GIVEN a dormant VM and a proxy that has vetted the request and
  stamped an attestation for that VM and lifecycle epoch
- WHEN trusted deliver runs
- THEN delivery follows the existing vsock / restore path

#### Scenario: Other topologies still act

- GIVEN a VM that an operator revives, Health reaps, or Reconcile
  resumes under `restart_policy: always`
- WHEN that path runs
- THEN it does not have to go through the request-admission facade
- AND a Buzz body with `restart_policy: never` is still not auto-resumed

### Requirement: Guests stay off the Erlang cluster

Guest VMs SHALL communicate with the host over vsock, Iroh, and the
HTTP gateway. They SHALL NOT join Distributed Erlang or expose EPMD.

#### Scenario: No cookie path into the guest

- GIVEN a running guest
- WHEN an operator inspects the guest’s listening ports and process
  list
- THEN there is no Erlang distribution listener accepting the host
  cookie

### Requirement: Protocol versus host policy

`identikey-protocol` SHALL own the portable admission *protocol*:
envelope format, attestation shape, verdict vocabulary (deny / drop /
reply-here / deliver), and pure validators. That artifact SHALL be
Apache-2.0 OR BSD-2-Clause-Patent and SHALL NOT depend on
`identikey-core`. Mjolnir SHALL own lifecycle policy: run state,
generation, `restart_policy`, shutdown latch, actor-to-VM map, and
whether restore is allowed. A conforming Mjolnir-local evaluator of
the protocol is permitted. Verifying a signed envelope is not
custody of the `nsec`.

#### Scenario: A second embedder can link the protocol

- GIVEN the admit protocol published from `identikey-protocol`
- WHEN a gateway plugin or CDN origin adapter depends on it
- THEN it does not pull `identikey-core` or an AGPL obligation

#### Scenario: Fail closed

- GIVEN the evaluator or catalog is unavailable (`pg_enabled` false,
  plugin crash, unknown envelope version)
- WHEN an untrusted wake is considered
- THEN the decision is deny or drop, never deliver or restore

### Requirement: Host sidecar is control-plane only

The OTP-managed Postgres sidecar SHALL store derived host-service
indexes (Sites, and later admit/forge catalogs) as **schemas in the
existing host database**, not as per-service `CREATE DATABASE`. It
SHALL NOT hold a tenant app database, a Buzz community event log, or
a database whose owner is a guest. Guests SHALL have no network path
to the sidecar socket, including via `extra_mounts`.

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
intentional harness exit (poweroff / `exited` 0) SHALL finalize the
record as `:stopped` via Reconcile, not via `DormantRegistry`.
`deliver_message` SHALL NOT treat `:stopped` as dormant. A `:never`
body SHALL NOT enter `DormantRegistry` through `handle_done` /
`signal_done` (refuse, same shape as `secrets_mode: :persistent`).
An unadmitted subsequent message SHALL NOT resume a `:stopped` or
dormant Buzz body. Owner revive, provider Start, and other
non-facade topologies remain available as specified by those paths.

#### Scenario: Shutdown then mention

- GIVEN a Buzz-managed VM whose harness exited 0 / `exited`
- WHEN a channel mention arrives and admission does not grant a wake
- THEN the VM remains `:stopped` (not dormant)
- AND Reconcile does not rehydrate it
- AND `deliver_message` returns not-found, not a restore

#### Scenario: signal_done is refused on never

- GIVEN a running Buzz body with `restart_policy: never`
- WHEN the guest sends `signal_done`
- THEN the host refuses dormancy
- AND the body is not registered in `DormantRegistry`

### Requirement: Secrets stay off the host artifacts

The agent `nsec` SHALL be treated as an opaque string, stored in
SecretStore, and injected over vsock. Host-originated artifacts
(VM record, API responses, host journald, host-written syslog
lines) SHALL NOT contain it. The harness SHALL NOT log it. A guest
that prints its own secret is out of scope for a host invariant.

#### Scenario: Negative scan of host artifacts

- GIVEN a successful deploy of a Buzz body
- WHEN the VM record, list/info API bodies, and host journald are
  searched for the nsec
- THEN there are no matches
