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

### Requirement: Protocol versus host policy

`identikey-protocol` SHALL own the portable admission *protocol*:
envelope format, attestation shape, verdict vocabulary (deny / drop /
reply-here / deliver), and pure validators. That artifact SHALL be
Apache-2.0 OR BSD-2-Clause-Patent and SHALL NOT depend on
`identikey-core`. Mjolnir SHALL own lifecycle policy. A conforming
Mjolnir-local evaluator of the protocol is permitted. v1 shape-check
in `Mjolnir.Admit` is that evaluator until the crate lands.

#### Scenario: A second embedder can link the protocol

- GIVEN the admit protocol published from `identikey-protocol`
- WHEN a gateway plugin or CDN origin adapter depends on it
- THEN it does not pull `identikey-core` or an AGPL obligation

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
