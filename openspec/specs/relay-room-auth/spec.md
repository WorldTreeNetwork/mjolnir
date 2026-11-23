# relay-room-auth

What is built. Folded from
[`add-relay-room-auth`](../../changes/archive/2026-11-23-add-relay-room-auth/proposal.md)
on 2026-11-23. Decisions: ADR
[`0016`](../../../docs/decisions/0016-edge-relay.md) (decision of
2026-11-22 and the fold note). Relay contract:
[`edge-relay`](../edge-relay/spec.md). Live on production since
2026-11-23: the controller mints at
`POST /api/relay/rooms/:room/participants/:participant/token` and a
room test with minted tokens passed (archived `notes/prod-enable.md`).

Notes on this fold:

- The default life is the lower of the ceiling and 3600 seconds. The
  pasted text said "the ceiling", which differs only when
  `MJOLNIR_RELAY_TOKEN_MAX_TTL` is above 3600 (`Mint.clamp_ttl/2`).
- A `MJOLNIR_RELAY_TOKEN_MAX_TTL` line that is not a positive integer is
  503. The paste did not say.
- The ceiling the mint enforces is `MJOLNIR_RELAY_TOKEN_MAX_TTL` in
  `/etc/mjolnir-relay/relay.env`, the same line the relay loads. The
  paste named `:relay_token_max_ttl` in one sentence; that config key is
  the default written to the env, not what the mint reads.
- Refusal order is the code's (see the first requirement). A `sub` that
  is not an owner gets 503, not 403, when the relay is not configured.
- Capability and ceremony principals get 401 from the auth plug and do
  not reach the route. Empty, `.` and `..` segments are 404 on the HTTP
  route. Both were in the paste as deviations from the first draft.
- The in-band second-token refusal is a unit assertion on the decider.
  The pinned moq-net takes no in-band tokens, so that line does not run
  on the live path.
- "The mint SHALL NOT sign with a key absent from the confirmed set" is
  the script's ordering. It was not separately observed.
- Make-before-break across a token boundary is not shown. It is a PUNT
  to `add-browser-call-client` (`mjolnir-rurh.5`). The measured gap is
  in the expiry requirement below.

## Purpose

The controller API mints a moq-auth relay token for one participant
label in one room of the caller's own tenant. The private signing key
is root-only on the controller host. The relay trusts its public half
through the key file `edge-relay` defines. `scripts/relay-mint-key.sh`
installs, rotates and emergency-revokes that key.

## Limits

- No per-participant, per-room or per-tenant revocation before `exp`.
  A removed participant keeps a working token, and may reconnect with
  it, until it expires. There is no kick.
- The mint key is host-wide. Whoever holds `current.jwk` can sign a
  root under any tenant on that relay.
- Emergency revoke drops every session on the host, every tenant, after
  the drain.
- Routine rotation, `finish` and `emergency` were exercised on the
  laptop only, not on production.
- A call ends at the token life (default 3600 seconds) until a client
  resubscribes when a publisher reconnects.
- No mint rate limit (`add-relay-limits-metering`, `mjolnir-rurh.4`).
  No media end-to-end encryption; the relay can read payloads
  (`mjolnir-rurh.9`).

## Requirements

### Requirement: The controller mints a room token for the caller
The Mjolnir API SHALL mint a moq-auth JWT for one participant label in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL be a user principal (`principal_kind == :user`) and SHALL present scope `relay:join`. The operator socket, a sites service token, and any other principal SHALL be refused with 403 before a signature, including when that principal holds `relay:join`.

The owner SHALL be the caller's verified `sub`, resolved as `Mjolnir.Deploy.Owner.resolve/2` resolves a non-operator, so `x-owner-id` is ignored. A canonical base58 `sub` SHALL be used as-is. A legacy 64-hex `sub` SHALL be re-encoded to canonical base58. Any other `sub` SHALL be refused with 403 before a signature. A body field `owner_id` SHALL be ignored. A user who sends another owner's id in the header SHALL NOT receive a token rooted at that other owner.

The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk` on every mint. The file and its directory SHALL be root-owned. The directory SHALL NOT be writable by group or other. The file SHALL NOT be readable or writable by group or other. A failed check SHALL be 503 and SHALL NOT sign. Enabled, host, and the token ceiling SHALL be read from `/etc/mjolnir-relay/relay.env` on every mint, not from the controller environment. A missing env file, a missing key, `MJOLNIR_RELAY_ENABLED` other than `true`, or an unset `MJOLNIR_RELAY_HOST` SHALL be 503 and SHALL NOT sign. The ceiling SHALL be `MJOLNIR_RELAY_TOKEN_MAX_TTL` in that file, or 3600 when the line is absent. A ceiling line that is not a positive integer SHALL be 503 and SHALL NOT sign.

The token SHALL be EdDSA, SHALL carry the signing key's `kid`, SHALL set integer `iat` and `exp`, SHALL set a `jti` of 22 base64url characters, and SHALL NOT set `aud` or any claim outside the moq-auth set `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. The default life SHALL be the lower of the ceiling and 3600 seconds. An omitted `ttl` means that default. Resubscribe-on-announce in the client is a precondition for a call longer than one token, and for returning to a short default. `ttl` SHALL be a JSON integer in the body. It SHALL be honored when it is greater than zero and at most the ceiling. `0`, a negative, a value above the ceiling, a string, and a float SHALL be 400 before a signature. The response SHALL be JSON with keys `token`, `expires`, `root`, `publish`, `subscribe`, and `relay_host`, and SHALL set `Cache-Control: no-store`. It SHALL NOT contain a private key. The mint SHALL log the caller's `sub`, the owner, the room, the participant label, the `jti`, and `exp`, and SHALL NOT log the token.

The owner check SHALL NOT trim. Legacy hex SHALL match `\A[0-9a-f]{64}\z`. The `sub` SHALL equal its canonical re-encode. A sites token is refused with 403 before a signature. A capability principal and a ceremony principal do not reach this route: the auth plug answers 401. The mint module, if those principals are passed in, returns 403.

The checks run in this order, and the first failure answers: scope `relay:join` (403 `insufficient_scope`), user principal (403 `forbidden`), room and participant segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), env file, ceiling line, enabled and host (503 `relay_unavailable`), `ttl` range (400 `bad_ttl`), owner (403 `forbidden`), key file mode and key (503 `relay_unavailable`). A `sub` that is not an owner therefore gets 503 while the relay is not configured.

#### Scenario: Authorized mint
- GIVEN a user with `relay:join` and a canonical `sub`
- WHEN they mint for a room and a participant whose segments match the path rule, with no `ttl`
- THEN the response token is signed by the current mint key and carries that key's `kid`
- AND its root is `t/<that sub>/<room>`
- AND its life is the lower of the ceiling and 3600 seconds (3600 when the ceiling line is absent)
- AND `x-owner-id`, if sent, is not the owner in the root

#### Scenario: Cross-tenant header
- GIVEN a user whose `sub` is owner A
- WHEN they mint with `x-owner-id` set to owner B
- THEN the token root is `t/<A>/<room>`
- AND no token rooted at B is signed

#### Scenario: Sub is not an owner
- GIVEN a configured relay and a user whose `sub` is neither canonical base58 nor 64-hex
- WHEN they mint
- THEN the response is 403 and no token is signed

#### Scenario: Operator
- GIVEN the operator principal, which holds every scope
- WHEN they call the mint
- THEN the response is 403 and no token is signed

#### Scenario: Relay not configured
- GIVEN no mint key, or the relay disabled, or the relay host unset
- WHEN a user with `relay:join` calls the mint
- THEN the response is 503 and no token is signed

### Requirement: A room path binds publish to one participant label
A room path SHALL be `t/<owner id>/<room>/<participant>/<rest>`. `<room>` and `<participant>` SHALL each match the whole string `\A[A-Za-z0-9_-]{1,64}\z`. The token root SHALL be `t/<owner id>/<room>`. The publish pattern SHALL be `<participant>/**`. The subscribe pattern SHALL be `**`. Patterns are exact: a name matches only that name, and a subtree is `/**`.

A WebTransport client is rooted at the token root. It publishes `P/track` and the exact name `P`. An Iroh client uses the absolute path `t/<owner>/R/P/track` and `t/<owner>/R/P`. The relay SHALL admit those publishes and SHALL refuse `Q` and `Q/track` in the spelling of that transport. A session admitted for room R SHALL be refused when it reads a broadcast under room S, in every spelling that transport can ask with, and its announcements SHALL list nothing from S. A segment that breaks the rule SHALL be refused with 400 before a signature. The refused segments include 65 characters, `%2F`, `%5C`, `*`, `%0A`, and a trailing newline. The empty segment, `.`, and `..` (including `%2E` and `%2E%2E`) are 404 `not_found` on the HTTP route, because Cowboy and Plug collapse those segments before the mint. The mint module still returns 400 for them.

Rooms are not stored and participant labels are not authenticated identities. The owner may mint a second token for a label already in use, and two live sessions may then publish as that label.

#### Scenario: Own track
- GIVEN a token minted for label P in room R
- WHEN a WebTransport client publishes `P/track` and `P`, and an Iroh client publishes `t/<owner>/R/P/track` and `t/<owner>/R/P`
- THEN those publishes are admitted
- AND a subscribe of room R on each transport receives them

#### Scenario: Another participant
- GIVEN a token minted for label P in room R
- WHEN a WebTransport client publishes `Q/track` and `Q`, and an Iroh client publishes `t/<owner>/R/Q/track` and `t/<owner>/R/Q`
- THEN those publishes are refused

#### Scenario: Another room, same session
- GIVEN a session admitted for room R on WebTransport, and one admitted on Iroh
- WHEN each asks for a broadcast under room S in the spellings that transport can use
- THEN each request is refused
- AND neither session's announcements list a broadcast from S

#### Scenario: No token
- GIVEN a client with no token
- WHEN it opens a session on a room path on WebTransport, and on Iroh
- THEN both sessions are refused

### Requirement: Expiry ends the session and the client reconnects first
The relay SHALL close a session when its token expires, on WebTransport and on Iroh. The mint SHALL NOT issue a token whose life exceeds the relay's ceiling, `MJOLNIR_RELAY_TOKEN_MAX_TTL` in `/etc/mjolnir-relay/relay.env` (default 3600). A second token presented on an open WebTransport session SHALL be refused. This capability SHALL NOT replace the grant of an open session. An Iroh session SHALL be admitted once. A client that still wants the room SHALL open a new session with a new token before the current token expires, then drop the old session. Two sessions MAY hold the same path during that handoff.

Measured, not promised: the relay does not bridge two publishers of one path. When a publisher's session ends and a new session publishes the same path, a subscriber that keeps its subscription receives nothing from the new session, on WebTransport and on Iroh, and nothing prompts it to resubscribe (no `Restart` was seen). A subscriber therefore loses that participant's media when the publisher reconnects, and a call ends at the token life (default 3600 seconds) until a client resubscribes on re-announce. Resubscribe and make-before-break are owed by `add-browser-call-client` (`mjolnir-rurh.5`).

#### Scenario: Call longer than the token
- GIVEN an admitted session whose token then reaches `exp`
- WHEN the relay applies that expiry
- THEN the session is closed on the transport it used
- AND a new session with a newly minted token for the same label is admitted

#### Scenario: Second token on a live WebTransport session
- GIVEN an admitted WebTransport session
- WHEN the client presents another token in band
- THEN the relay refuses that token
- AND the session's grant is unchanged

### Requirement: Routine rotation overlaps public keys and switches the signer after
An operator routine rotation, run as root on the same host as the relay, SHALL give every key a unique `kid`. It SHALL write the next private key beside the current one, SHALL validate the public set of both, and SHALL rename that set into `/etc/mjolnir-relay/relay-keys.json`. It SHALL switch the signer to the next key only after `/run/mjolnir-relay/keys.active` equals that file's SHA-256. If `keys.active` is `invalid` or unchanged for ten seconds, it SHALL restore the previous public set and SHALL leave the signer unchanged. The first install SHALL make the public set exactly the mint key and SHALL remove any earlier key. After `:relay_token_max_ttl` plus 60 seconds it SHALL publish a set of the new key only and SHALL confirm `keys.active` again. A session already admitted SHALL keep that admission until its token expires. A new session whose token was signed by a key still in the set SHALL be admitted. No step SHALL send key material through the gateway user or through an API route. The mint SHALL NOT sign with a key absent from the set the relay has confirmed.

The procedure is `scripts/relay-mint-key.sh` as root, under one `flock` for install, rotation and emergency. Step 5 is a second invocation, `relay-mint-key.sh finish`, gated by `/var/lib/mjolnir/relay-mint/rotation.json`. Routine rotation shortens no token and removes no participant.

#### Scenario: Both keys during the overlap
- GIVEN a public set holding the current key and the next key, each with its own `kid`
- WHEN a new session presents a token signed by either key, and the token carries that key's `kid`
- THEN the session is admitted

#### Scenario: No kid against two keys
- GIVEN a public set of two keys
- WHEN a token with no `kid` is presented
- THEN the session is refused

#### Scenario: Confirmation fails
- GIVEN a candidate public set the relay marks `invalid`
- WHEN rotation publishes it
- THEN the previous public set is restored
- AND the signer is still the key that was current before the attempt

### Requirement: Emergency revoke drops every call on the host
An emergency revoke SHALL publish only a new key, with no overlap. It SHALL delete `next.jwk` when that file exists. It SHALL NOT restore the previous public set, including when `keys.active` is `invalid` or unchanged for ten seconds. It SHALL still restart the relay in that case and SHALL exit non-zero. It SHALL switch the signer only after `keys.active` matches. A restart SHALL drain for the `MJOLNIR_RELAY_DRAIN_SECONDS` the process loaded at start, default 30. This node SHALL NOT shorten that drain. A live session SHALL survive the drain. New sessions SHALL be refused once the new set is loaded. The procedure is host-wide: every tenant on that relay drops, and the mint key can sign any tenant. It SHALL NOT be the routine rotation.

#### Scenario: Stolen mint key
- GIVEN a routine overlap would leave the old public key in the set
- WHEN the operator runs the emergency procedure instead
- THEN the public set does not contain the old key
- AND the relay process has restarted
- AND a token signed by the old key is refused
