# add-relay-guest-advert

> **ACTIVE BUILD**

## Why

Guests have no relay locator, and signed-in `mj` users have to construct the room-token API request themselves. Guests need the host's public dial targets, and users need a command that requests a room token with their saved session.

## What

- Advertise the WebTransport URL and public Iroh endpoint ID together in `/etc/mjolnir/vm.json` at guest boot and resume. The relay publishes its public identity through its systemd runtime directory.
- Add the edge relay to the host-sidecars catalog as a public UDP 443 service with optional guest locators.
- Add `mj relay token <room> <participant> [--api <url>] [--json]` over the existing room-token POST.

## Impact

- Capabilities modified by added requirements: `edge-relay` and `relay-room-auth`.
- ADRs: none.
- Production activation is owner-gated. This changes the relay binary, and production guests will see no relay fields until the owner runs `deploy.sh --relay` and a normal app deploy, then the guests boot or resume. The relay deploy restarts the relay and drains live sessions. The guest agent is unchanged and needs no `--agent` rebuild. The implementer runs neither deploy.

## User journey & surfaces

- A guest app reads `relay_url` for WebTransport or `relay_iroh_endpoint_id` for Iroh from `/etc/mjolnir/vm.json`. Both fields are absent when the local relay is disabled or its locator inputs are unavailable at guest setup.
- A signed-in user runs `mj relay token demo alice` and receives one token on stdout. With `--json`, stdout receives the successful response body as returned by the API. Failure exits nonzero with a safe diagnostic on stderr and empty stdout.
- The host-sidecars catalog shows the two fields, when they refresh, how to request a token, and where to find the operator runbook.

## Preparation

Node `mjolnir-rurh.6` was activated on 2026-11-25 under the campaign authority on `mjolnir-rurh`. The folded edge relay (`ca61ceb`) and room mint (`3755123`) supply the listener, Iroh identity and authenticated POST. The current release sources still expose those prerequisites. The independent [advise review](reviews/2026-11-25-advise.md) accepted the contract with the production gate and stale-locator guidance recorded here and in the tasks.

## Out of scope

- Changes to the mint, route shape, claims, principal handling, or signing keys. Open-room behavior is owned by `mjolnir-rurh.11`.
- Live refresh of guest metadata between guest setups.
- The `--ttl` and `--kind` command options, pending the owner's follow-up decision.
- Relay deployment, firewall changes and production verification.
