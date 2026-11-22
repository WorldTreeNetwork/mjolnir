# add-relay-room-auth

> **ACTIVE BUILD**

## Why

The edge relay admits a moq-auth JWT whose root is `t/<owner id>` or below it. Nothing yet says which caller may mint that token, which path is one participant in one room, or what happens when that participant is removed. `mjolnir-rurh.3` is that contract. The Iroh close at `exp` already landed in `105acf0`. The mint, the rotation script, and the room tests are this change.

A removed participant keeps a working token until it expires. They stay connected for that time and may reconnect any number of times inside it. There is no per-participant, per-room, or per-tenant revocation in this node. Routine key rotation does not shorten a token. The only early cut is the emergency procedure below, and it drops every call on the host.

## What

- Capability `relay-room-auth` (new). Token profile, key file, and the close at `exp` stay as `add-edge-relay` defined them, including the Iroh close fixed after that contract's acceptance notes (see that change's acceptance note "Iroh expiry").
- The controller API mints one room token per participant label, for a user principal only, under scope `relay:join`. The owner in the root is that caller's verified `sub`.
- A room is `t/<owner>/<room>`. Publish is `<participant>/**`. Subscribe is `**`. Patterns are exact.
- The mint's default life is the ceiling, 3600 seconds unless the relay env sets a lower `MJOLNIR_RELAY_TOKEN_MAX_TTL`. A caller may ask for a shorter `ttl`, never above that ceiling. Resubscribe-on-announce is a precondition for a call longer than one token. The relay refuses a second token on an open WebTransport session when the client can present one. The pinned moq-net client does not present in-band tokens. Iroh admits once.
- Routine rotation publishes the next public key, confirms the relay loaded it, and only then switches the signer. Emergency revoke replaces the public set with a new key and restarts the relay.

## Impact

- Capabilities: ADDED `relay-room-auth`. No living requirement is modified. `edge-relay` is still only a change, not a living spec.
- ADRs: none in this change. Fold may add a short note under ADR 0016 when the mint exists. This change does not amend ARCHITECTURE.md.

## User journey & surfaces

No new UI because the browser client is `mjolnir-rurh.5` (`call-client`). The minter that exists today is a signed-in user (`mj` or `curl` with that user's bearer). A guest who has a link and no Mjolnir login does not call this route. The room's owner mints a token for a participant label and hands that bearer to the guest. The guest cannot mint again. The token the owner hands a guest lasts until that token's `exp`. The default is the ceiling, so a guest call lasts up to 3600 seconds unless the owner asked for less. There is no kick. Opening the next session before `exp` is an obligation of `call-client` (`mjolnir-rurh.5`). This node does not promise a seamless handoff. A delegated invite, where a guest holds a capability that mints its own token, is a later change.

A second Mjolnir user cannot join another user's room by logging in. Their `sub` is a different owner, so the mint roots the token at their own tenant.

Working: the owner asks for a token for a room and a label, receives a JWT, and a client that presents it subscribes to that room and publishes only under that label. Empty: there is no mint key, the relay is disabled, or the host is unset, and the route returns 503 without signing. Failed: no token, a publish or subscribe outside the grant, or a user naming another owner is refused. Off: same as empty. The route does not return a token for a relay that is not configured.

## Out of scope

- Per-room rate limits, metering, and a limit on how often the mint may be called: `add-relay-limits-metering` (`mjolnir-rurh.4`). That bead owns the mint rate limit. This node does not.
- Media end-to-end encryption: `call-media-e2ee` (`mjolnir-rurh.9`). The relay still terminates QUIC and can read payloads.
- The browser client: `call-client` (`mjolnir-rurh.5`). Path spelling on the wire is this contract's. Attributing a track by the first segment as received, and look-alike labels (`alice`, `Alice`, `a1ice`), are that client's.
- Guest advertisement of the relay: `mjolnir-rurh.6`.
- A room registry, a membership list, a per-participant kick, and a delegated invite.
- Changing the moq-auth claim dialect, the 3600-second maximum, or the rule that an Iroh endpoint id grants nothing.
