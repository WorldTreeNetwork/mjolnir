# add-relay-room-auth

> **PENDING**

## Why

The edge relay admits any moq-auth JWT whose root is `t/<owner id>` or below it. Nothing yet says which path is a room, which caller may mint that token, or how a participant is stopped from publishing on another participant's path. `mjolnir-rurh.3` is that contract. No code in this change.

## What

- Capability `relay-room-auth` (new). The relay's token profile, key file, and expiry close stay as `add-edge-relay` defined them.
- The controller API mints one room token per participant, under a new scope, signed with a key whose public half is already in `/etc/mjolnir-relay/relay-keys.json`.
- A room is `t/<owner>/<room>/<participant>/…`. The token's publish set is that participant only. Its subscribe set is the room.
- A call longer than the token life ends. The client reconnects. The relay does not re-admit a live session.
- Revocation is rotation of the signing key, with an overlap of one maximum token life. Live sessions keep the admission they already have until that token expires.

## Impact

- Capabilities: ADDED `relay-room-auth`. No living requirement is modified. `edge-relay` is still only a change, not a living spec.
- ADRs: none in this change. Fold may add a short note under ADR 0016 when the mint exists. This change does not amend ARCHITECTURE.md.

## User journey & surfaces

No new UI because the browser client is `mjolnir-rurh.5` (`call-client`). The caller that exists today is an authenticated API client (`mj` or `curl` with the same bearer as other `/api` routes) and the two relay transports already proved in `add-edge-relay`.

Working: the caller asks for a token for a room and a participant, receives a JWT, and a client that presents it can subscribe to that room and publish only under that participant. Empty: the relay key file has no public key yet, so the mint fails before it signs. Failed: no token, a token for another room, or a publish on another participant's path is refused on WebTransport and on Iroh. Off: `MJOLNIR_RELAY_ENABLED` is not `true`, so the mint still returns a token but names the configured host, and nothing is listening.

## Out of scope

- Per-room rate limits and metering: `add-relay-limits-metering` (`mjolnir-rurh.4`).
- Media end-to-end encryption: `call-media-e2ee` (`mjolnir-rurh.9`). The relay still terminates QUIC and can read payloads.
- The browser client: `call-client` (`mjolnir-rurh.5`).
- Guest advertisement of the relay: `mjolnir-rurh.6`.
- A room registry, membership list, or per-participant kick list. Revocation in this node is the signing key, not a row.
- Changing the moq-auth claim dialect, the 3600-second maximum life, or the rule that an Iroh endpoint id grants nothing.
