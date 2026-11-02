# add-guest-fence-host

> **ACTIVE BUILD**

Bead `mjolnir-reki.5`. **Rigor:** instrument. Group: human-gate. Activated by the campaign grant on `mjolnir-reki` ("activate and run"). `fence-channel` is `go` (`docs/spikes/fence-channel/finding.md`). That finding does not pick a transport or a storage engine.

## Why

api-proxy already has the guest trait `HostFence` in `src/fence.rs`: `identity`, `classify`, `begin_adoption`, `confirm`, and `commit`. The implementation behind that trait is synthetic. Mjolnir has no host service that supplies journal identity, the owner-instance handle, or the generation from an authenticated channel.

## What

- A host service whose results satisfy that trait.
- Identity, instance handle, and monotonic generation come from the authenticated channel, not from the guest disk.
- `classify` covers every retained admission, including missing keys. An uncertain row stops adoption.
- `begin_adoption` returns the existing pending or confirmed grant for the host-designated instance. It does not demote a confirmed grant. A copied grant does not elect a new owner. An undesignated instance cannot elect itself.
- `commit(Adopt)` validates the supplied grant and does not issue another one. Acceptance is durable before the guest write is invoked or released, including when commit never returns, on the same boundary as transfer and revocation.
- Lost contact drops the lease. Already admitted rows are not resent.
- Transfer revokes the old grant and issues a new instance handle. A restored or cloned guest gets a new generation and drops the old grants.
- Receipts carry no secrets and are not exactly-once proof.
- The wire is not chosen. Act waits on `fence-channel`.

## Impact

- Capabilities: ADDED `guest-fence`
- ADRs: none in this change. The channel choice is still a spike.

## User journey & surfaces

No new UI because a guest proxy calls the host fence. The operator does not get a screen. A copied grant does not become owner. An uncertain classification does not adopt.

- **Working** — one live instance, a complete classification, and a grant that matches that instance.
- **Empty** — no retained admissions. Adoption may proceed only when classification is complete for that empty set.
- **Failed** — an uncertain or uncovered row. Adoption stops.
- **Off** — admitting an effect does not permit a send. `POST /v1/execute` stays locked in api-proxy.

## Out of scope

- The api-proxy client that dials this service.
- Replacing the synthetic `HostFence` in api-proxy.
- Tokenator mint, redeem, and hop.
- A send permit. `HostFence::commit` is not permission to send.
- Choosing the channel in this draft. That is `fence-channel`.

## Preparation

Outcome: revised. The guest trait is `~/work/IdentiKey/api-proxy/src/fence.rs`. Mjolnir has no module that implements it. Steer 2026-10-31: spike before act. The spike line stays unverified (low, not empirically-tested). No `docs/spikes/fence-channel/finding.md`. Authority: campaign grant on `mjolnir-reki`, this dependency-ready node. The 2026-10-31 re-advise sent the contract back. This pass answers the four follow-ups: full adoption retry keeps pending or confirmed state, the accepting owner's coverage advances with its own mutations, unknown-key refusal is Reconcile and classification only, and acceptance is durable before the guest write. The third advise sent three corrections back: stale coverage is a separately issued classification id, a receipt generation matches its own admission, and Reconcile does not carry a digest. Fresh advise is owed before act. Act still does not start until `fence-channel` says go or the line is skipped.
