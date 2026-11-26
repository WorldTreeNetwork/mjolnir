## MODIFIED Requirements

### Requirement: The controller mints a room token for the caller
<!-- base: fe562845ecfd16cb45fb2ad13b6f29ec758aeffa openspec/specs/relay-room-auth/spec.md -->
The Mjolnir API SHALL mint a moq-auth JWT for one participant label in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL be a user principal (`principal_kind == :user`) and SHALL present scope `relay:join`. The operator socket, a sites service token, and any other principal SHALL be refused with 403 before a signature, including when that principal holds `relay:join`.

The owner SHALL be the caller's verified `sub`, resolved as `Mjolnir.Deploy.Owner.resolve/2` resolves a non-operator, so `x-owner-id` is ignored. A canonical base58 `sub` SHALL be used as-is. A legacy 64-hex `sub` SHALL be re-encoded to canonical base58. Any other `sub` SHALL be refused with 403 before a signature. A body field `owner_id` SHALL be ignored. A user who sends another owner's id in the header SHALL NOT receive a token rooted at that other owner.

The room's kind SHALL come from the JSON body field `kind` and from nowhere else. `kind` SHALL be the string `open` or the string `protected`. An omitted `kind` means `protected`. `null`, any other string (compared exactly, not trimmed or case-folded), a number, a boolean, a list and an object SHALL be 400 `bad_kind` before a signature. A header (including `x-room-kind`), a query parameter, and the path SHALL NOT set or change the kind.

The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk` on every mint. The file and its directory SHALL be root-owned. The directory SHALL NOT be writable by group or other. The file SHALL NOT be readable or writable by group or other. A failed check SHALL be 503 and SHALL NOT sign. Enabled, host, and the token ceiling SHALL be read from `/etc/mjolnir-relay/relay.env` on every mint, not from the controller environment. A missing env file, a missing key, `MJOLNIR_RELAY_ENABLED` other than `true`, or an unset `MJOLNIR_RELAY_HOST` SHALL be 503 and SHALL NOT sign. The ceiling SHALL be `MJOLNIR_RELAY_TOKEN_MAX_TTL` in that file, or 3600 when the line is absent. A ceiling line that is not a positive integer SHALL be 503 and SHALL NOT sign.

The token SHALL be EdDSA, SHALL carry the signing key's `kid`, SHALL set integer `iat` and `exp`, SHALL set a `jti` of 22 base64url characters, and SHALL NOT set `aud` or any claim outside the moq-auth set `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. The kind SHALL be carried only by the root (see "A room path binds publish to one participant label"); the token SHALL carry no claim of its own for it. A token minted with `kind` omitted or `protected` SHALL have the same claim names and the same root as a token minted before the field existed. The default life SHALL be the lower of the ceiling and 3600 seconds. An omitted `ttl` means that default. Resubscribe-on-announce in the client is a precondition for a call longer than one token, and for returning to a short default. `ttl` SHALL be a JSON integer in the body. It SHALL be honored when it is greater than zero and at most the ceiling. `0`, a negative, a value above the ceiling, a string, and a float SHALL be 400 before a signature. The response SHALL be JSON with keys `token`, `expires`, `root`, `publish`, `subscribe`, `relay_host`, and `kind`, and SHALL set `Cache-Control: no-store`. `kind` SHALL be `open` or `protected` and SHALL always be present. It SHALL NOT contain a private key. The mint SHALL log the caller's `sub`, the owner, the room, the kind, the participant label, the `jti`, and `exp`, and SHALL NOT log the token.

The owner check SHALL NOT trim. Legacy hex SHALL match `\A[0-9a-f]{64}\z`. The `sub` SHALL equal its canonical re-encode. A sites token is refused with 403 before a signature. A capability principal and a ceremony principal do not reach this route: the auth plug answers 401. The mint module, if those principals are passed in, returns 403.

The checks run in this order, and the first failure answers: scope `relay:join` (403 `insufficient_scope`), user principal (403 `forbidden`), room and participant segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), `kind` (400 `bad_kind`), env file, ceiling line, enabled and host (503 `relay_unavailable`), `ttl` range (400 `bad_ttl`), owner (403 `forbidden`), key file mode and key (503 `relay_unavailable`). A `sub` that is not an owner therefore gets 503 while the relay is not configured. A bad `kind` gets 400 whether or not the relay is configured.

#### Scenario: Authorized mint
- GIVEN a user with `relay:join` and a canonical `sub`
- WHEN they mint for a room and a participant whose segments match the path rule, with no `ttl` and no `kind`
- THEN the response token is signed by the current mint key and carries that key's `kid`
- AND its root is `t/<that sub>/<room>`
- AND the response `kind` is `protected`
- AND the token's claim names are exactly `exp`, `iat`, `jti`, `publish`, `root`, `subscribe`
- AND its life is the lower of the ceiling and 3600 seconds (3600 when the ceiling line is absent)
- AND `x-owner-id`, if sent, is not the owner in the root

#### Scenario: Open room mint
- GIVEN a user with `relay:join` and a canonical `sub`
- WHEN they mint for room R and label P with body `{"kind":"open"}`
- THEN the token root is `t/<that sub>/~open/R`
- AND publish is `P/**` and subscribe is `**`
- AND the token's claim names are the same as a protected mint's
- AND the response `kind` is `open`

#### Scenario: Explicit protected
- GIVEN a user with `relay:join`
- WHEN they mint with body `{"kind":"protected"}`
- THEN the token root is `t/<that sub>/<room>` and the response `kind` is `protected`

#### Scenario: Bad kind
- GIVEN a user with `relay:join`, with the relay configured and, separately, with the env file missing
- WHEN they mint with `kind` set to `"Open"`, `"open "`, `""`, `null`, `1`, `true`, `["open"]` or `{}`
- THEN the response is 400 `bad_kind` in both configurations
- AND no token is signed

#### Scenario: Kind outside the body
- GIVEN a user with `relay:join`
- WHEN they mint with no body `kind` and with the header `x-room-kind: open`, or the query `?kind=open`
- THEN the token root is `t/<that sub>/<room>` and the response `kind` is `protected`

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
<!-- base: fe562845ecfd16cb45fb2ad13b6f29ec758aeffa openspec/specs/relay-room-auth/spec.md -->
A room root SHALL be `t/<owner id>/<room>` for a protected room and `t/<owner id>/~open/<room>` for an open room. A room path SHALL be `<room root>/<participant>/<rest>`. `<room>` and `<participant>` SHALL each match the whole string `\A[A-Za-z0-9_-]{1,64}\z`. The segment `~open` is outside that alphabet, so it SHALL NOT be accepted as a `<room>` or `<participant>` segment. The token root SHALL be the room root. The publish pattern SHALL be `<participant>/**`. The subscribe pattern SHALL be `**`. Patterns are exact: a name matches only that name, and a subtree is `/**`.

A WebTransport client is rooted at the token root. It publishes `P/track` and the exact name `P`. An Iroh client uses the absolute path `<room root>/P/track` and `<room root>/P`, for example `t/<owner>/R/P/track` in a protected room and `t/<owner>/~open/R/P/track` in an open room. The relay SHALL admit those publishes and SHALL refuse `Q` and `Q/track` in the spelling of that transport. A session admitted for room R SHALL be refused when it reads a broadcast under room S, in every spelling that transport can ask with, and its announcements SHALL list nothing from S. The open room R and the protected room R of one owner are different rooms for this rule. A segment that breaks the rule SHALL be refused with 400 before a signature. The refused segments include 65 characters, `%2F`, `%5C`, `*`, `%0A`, `~open`, and a trailing newline. The empty segment, `.`, and `..` (including `%2E` and `%2E%2E`) are 404 `not_found` on the HTTP route, because Cowboy and Plug collapse those segments before the mint. The mint module still returns 400 for them.

Rooms are not stored and participant labels are not authenticated identities. The owner may mint a second token for a label already in use, and two live sessions may then publish as that label.

#### Scenario: Own track
- GIVEN a token minted for label P in room R, protected and, separately, open
- WHEN a WebTransport client publishes `P/track` and `P`, and an Iroh client publishes `<room root>/P/track` and `<room root>/P`
- THEN those publishes are admitted
- AND a subscribe of the same room R, of the same kind, on each transport receives them

#### Scenario: Another participant
- GIVEN a token minted for label P in room R
- WHEN a WebTransport client publishes `Q/track` and `Q`, and an Iroh client publishes `t/<owner>/R/Q/track` and `t/<owner>/R/Q`
- THEN those publishes are refused

#### Scenario: Another room, same session
- GIVEN a session admitted for room R on WebTransport, and one admitted on Iroh
- WHEN each asks for a broadcast under room S in the spellings that transport can use
- THEN each request is refused
- AND neither session's announcements list a broadcast from S

#### Scenario: Open and protected rooms of one name
- GIVEN one owner, a session admitted with an open token for room R and a session admitted with a protected token for room R, on WebTransport and on Iroh
- WHEN each publishes under its own label and asks for the other's broadcast in every spelling its transport can use
- THEN each request for the other room is refused
- AND neither session's announcements list a broadcast from the other room

#### Scenario: Marker as a segment
- GIVEN a user with `relay:join`
- WHEN they mint for room `~open` or for participant `~open` through the mint module
- THEN the response is 400 `bad_segment` and no token is signed

#### Scenario: No token
- GIVEN a client with no token
- WHEN it opens a session on a room path on WebTransport, and on Iroh
- THEN both sessions are refused

## ADDED Requirements

### Requirement: A room's kind is fixed by its root
A room SHALL be identified by its owner, its kind and its name. A room's kind SHALL be determined only by the token root. A root of exactly `t/<canonical owner id>/~open/<room>` names an open room. A root of exactly `t/<canonical owner id>/<room>` names a protected room. `<room>` follows the segment rule. Any other root, including `t/<owner id>` alone, `t/<owner id>/~open`, `t/<owner id>/<room>/~open` and a root with further segments, SHALL NOT be read as a room of either kind. `mjolnir_relay::room_kind` SHALL implement that reading, and every Mjolnir component that decides by kind SHALL use it or an equivalent with the same tests. A root without the marker SHALL be read as protected, including every token minted before this requirement.

No Mjolnir component SHALL store a room's kind or take it from anything but the verified root. A room SHALL NOT change kind. An owner who wants the other kind mints tokens of that kind, which name a different room. Tokens for the first room keep their admission until they expire.

A Mjolnir component that admits WebRTC media, by WHIP publish or WHEP play or any successor, SHALL admit it only with a verified room token whose root names an open room. It SHALL refuse a protected root and a root that names no room with 403 `room_not_open` before it sends any SDP answer. It SHALL reach the relay for that leg only with that leg's own room token, and SHALL hold no relay credential whose root reaches a protected room. The relay SHALL admit sessions of both kinds under the same rules. It SHALL NOT read the kind. Its root scoping is what keeps a room of one kind apart from a room of the other.

A room's kind is the owner's declaration. `protected` does not prove that clients encrypt, and `open` does not stop a client from encrypting.

#### Scenario: Reading roots
- GIVEN the roots `t/<owner>/~open/R`, `t/<owner>/R`, `t/<owner>`, `t/<owner>/~open`, `t/<owner>/R/~open`, `t/<owner>/~open/R/x`, `t/<owner>/~open/R!`, and `t/<non-canonical>/~open/R`
- WHEN `room_kind` reads each
- THEN the first is open room R, the second is protected room R, and every other root names no room

#### Scenario: Token minted before this change
- GIVEN a token minted by the controller before the `kind` field existed, rooted at `t/<owner>/R`
- WHEN the relay verifies it and `room_kind` reads its root
- THEN the relay admits it as before
- AND it names protected room R

#### Scenario: Deployed relay and an open token
- GIVEN the relay verifier at the commit running on production
- WHEN it is given a token minted by this change with `kind` `open` for label P in room R
- THEN `assess` and `web_grant` admit it on the path `t/<owner>/~open/R`
- AND the Iroh grant publishes `t/<owner>/~open/R/P/**` and subscribes `t/<owner>/~open/R/**`

#### Scenario: WebRTC into a protected room
- GIVEN a valid token for protected room R
- WHEN a client sends a WHIP offer or a WHEP offer for room R with it
- THEN the edge answers 403 `room_not_open`
- AND no SDP answer is sent and no relay session is opened

#### Scenario: WebRTC into an open room
- GIVEN a valid token for open room R and label P
- WHEN a client sends a WHIP offer for `P/cam` in room R
- THEN the edge admits it and publishes through a relay session opened with that same token
