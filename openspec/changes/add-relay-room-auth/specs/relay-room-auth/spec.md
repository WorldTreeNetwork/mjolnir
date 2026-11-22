## ADDED Requirements

### Requirement: The controller mints a room token for the caller
The Mjolnir API SHALL mint a moq-auth JWT for one participant label in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL be a user principal (`principal_kind == :user`) and SHALL present scope `relay:join`. The operator socket, a sites service token, and any other principal SHALL be refused with 403 before a signature, including when that principal holds `relay:join`.

The owner SHALL be the caller's verified `sub`, resolved as `Mjolnir.Deploy.Owner.resolve/2` resolves a non-operator, so `x-owner-id` is ignored. A canonical base58 `sub` SHALL be used as-is. A legacy 64-hex `sub` SHALL be re-encoded to canonical base58. Any other `sub` SHALL be refused with 403 before a signature. A body field `owner_id` SHALL be ignored. A user who sends another owner's id in the header SHALL NOT receive a token rooted at that other owner.

The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk` on every mint. The file and its directory SHALL be root-owned. The directory SHALL NOT be writable by group or other. The file SHALL NOT be readable or writable by group or other. A failed check SHALL be 503 and SHALL NOT sign. Enabled, host, and the token ceiling SHALL be read from `/etc/mjolnir-relay/relay.env` on every mint, not from the controller environment. A missing env file, a missing key, `MJOLNIR_RELAY_ENABLED` other than `true`, or an unset `MJOLNIR_RELAY_HOST` SHALL be 503 and SHALL NOT sign. The ceiling SHALL be `MJOLNIR_RELAY_TOKEN_MAX_TTL` in that file, or 3600 when the line is absent.

The token SHALL be EdDSA, SHALL carry the signing key's `kid`, SHALL set integer `iat` and `exp`, SHALL set a `jti` of 22 base64url characters, and SHALL NOT set `aud` or any claim outside the moq-auth set `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. The default life SHALL be the ceiling (3600 seconds when `MJOLNIR_RELAY_TOKEN_MAX_TTL` is absent), and a lower ceiling SHALL be the default. An omitted `ttl` means that default. Resubscribe-on-announce in the client is a precondition for a call longer than one token, and for returning to a short default. `ttl` SHALL be a JSON integer in the body. It SHALL be honored when it is greater than zero and at most the ceiling. `0`, a negative, a value above the ceiling, a string, and a float SHALL be 400 before a signature. The response SHALL be JSON with keys `token`, `expires`, `root`, `publish`, `subscribe`, and `relay_host`, and SHALL set `Cache-Control: no-store`. It SHALL NOT contain a private key. The mint SHALL log the caller's `sub`, the owner, the room, the participant label, the `jti`, and `exp`, and SHALL NOT log the token.

The owner check SHALL NOT trim. Legacy hex SHALL match `\A[0-9a-f]{64}\z`. The `sub` SHALL equal its canonical re-encode. A sites token is refused with 403 before a signature. A capability principal and a ceremony principal do not reach this route: the auth plug answers 401. The mint module, if those principals are passed in, returns 403.

#### Scenario: Authorized mint
- GIVEN a user with `relay:join` and a canonical `sub`
- WHEN they mint for a room and a participant whose segments match the path rule, with no `ttl`
- THEN the response token is signed by the current mint key and carries that key's `kid`
- AND its root is `t/<that sub>/<room>`
- AND its life is the ceiling (3600 seconds when the ceiling line is absent)
- AND `x-owner-id`, if sent, is not the owner in the root

#### Scenario: Cross-tenant header
- GIVEN a user whose `sub` is owner A
- WHEN they mint with `x-owner-id` set to owner B
- THEN the token root is `t/<A>/<room>`
- AND no token rooted at B is signed

#### Scenario: Sub is not an owner
- GIVEN a user whose `sub` is neither canonical base58 nor 64-hex
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
The relay SHALL close a session when its token expires, on WebTransport and on Iroh. The mint SHALL NOT issue a token whose life exceeds `:relay_token_max_ttl`. A second token presented on an open WebTransport session SHALL be refused. This capability SHALL NOT replace the grant of an open session. An Iroh session SHALL be admitted once. A client that still wants the room SHALL open a new session with a new token before the current token expires, then drop the old session. Two sessions MAY hold the same path during that handoff.

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
