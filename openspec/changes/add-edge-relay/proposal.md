# add-edge-relay

> **ACTIVE BUILD** — campaign authority on `mjolnir-rurh` 2026-11-20 (Duke: "activate"). Node `mjolnir-rurh.1` (architecture) and `mjolnir-rurh.2` (service). No write work before an advise accept and ADR 0016.

## Why

A browser cannot speak Iroh. It reaches a Media-over-QUIC relay only by WebTransport, which needs a UDP port it can address and a certificate it trusts. A call with more than a handful of people also needs each sender to upload once and a relay to fan out. Mjolnir has neither today. The 2026-11-20 spike ran `iroh-live-relay` in a guest behind a published UDP port and a browser played a broadcast, but only with a self-signed certificate, a host-side TCP forward and a page loaded from `localhost` (bead `mjolnir-pfeq`).

## What

- A host service, `mjolnir-relay`, in its own process and systemd unit beside the gateway. Capability: `edge-relay`.
- It listens for WebTransport on UDP 443 at one configured name, with a certificate from the gateway's issuer. It never falls back to a self-signed certificate.
- It accepts Iroh sessions on its own Iroh endpoint, so a native client or a guest can publish and read without a public address.
- Every session needs a token the relay can verify. A session without one is refused.
- It does not dial out on a client's request (no ticket pulls).
- Off by default. A host that does not enable it is unchanged.

**Rigor:** architecture. **Blast:** new public UDP listener on prod, authorisation, a pre-1.0 protocol dependency.

Design and the decisions the ADR will record: [`design.md`](design.md).

## Impact

- Capabilities: ADDED `edge-relay`.
- ADRs: new `docs/decisions/0016-edge-relay.md`.
- Code: new crate `native/mjolnir_relay`; `systemd/mjolnir-relay.service`; `scripts/deploy.sh` (`--relay`); `scripts/build-native.sh`; config keys for the name and the enable flag.
- Host: a new system user, UDP 443 opened in the host firewall, one more certificate subject.
- Not changed: the gateway binary, guest images, published UDP ports.

## User journey & surfaces

No new UI because this change ships the service and its operator surface only. The browser client is `add-browser-call-client` (`mjolnir-rurh.5`).

- Operator enables the relay and deploys with `./scripts/deploy.sh <host> --relay`.
- `systemctl status mjolnir-relay` shows it active; its log prints the name it serves and its Iroh endpoint id.
- Off: the unit is not installed and UDP 443 is closed.
- Failed: with no valid certificate for the name the unit fails at start and says which file it wanted.
- Acceptance uses iroh-live's stock viewer page and `irl publish --relay`, with a token made from the operator's key.

## Preparation

- Inputs: spike results in bead `mjolnir-rurh.1` notes (iroh-live `747b1bd`, moq `4a6f522`); `mjolnir-pfeq`; living specs `site-certs`, `edge-auth`.
- Outcome: new contract. Authority: the grant above, inside the non-goals on `mjolnir-rurh`.

## Out of scope

- Minting room tokens from the Mjolnir API and the claim layout per room: `add-relay-room-auth` (`mjolnir-rurh.3`).
- Per-tenant limits and byte accounting: `mjolnir-rurh.4`.
- The browser client: `mjolnir-rurh.5`.
- Telling guests where the relay is: `mjolnir-rurh.6`.
- Measured capacity: `mjolnir-rurh.7`.
- A self-hosted Iroh relay: `mjolnir-rurh.8`.
- End-to-end media encryption. The relay terminates QUIC, so the host can read media. Not tracked yet; see the decision briefing.
- A second region, recording, Safari.
