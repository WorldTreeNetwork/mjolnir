## MODIFIED Requirements

### Requirement: The controller mints a room token for the caller
<!-- base: fe562845ecfd16cb45fb2ad13b6f29ec758aeffa openspec/specs/relay-room-auth/spec.md -->
The Mjolnir API SHALL mint a moq-auth JWT for one participant label in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL be a user principal (`principal_kind == :user`) and SHALL present scope `relay:join`. The operator socket, a sites service token, and any other principal SHALL be refused with 403 before a signature, including when that principal holds `relay:join`.

The owner SHALL be the caller's verified `sub`, resolved as `Mjolnir.Deploy.Owner.resolve/2` resolves a non-operator, so `x-owner-id` is ignored. A canonical base58 `sub` SHALL be used as-is. A legacy 64-hex `sub` SHALL be re-encoded to canonical base58. Any other `sub` SHALL be refused with 403 before a signature. A body field `owner_id` SHALL be ignored. A user who sends another owner's id in the header SHALL NOT receive a token rooted at that other owner.

The room's kind SHALL come from the JSON body field `kind` and from nowhere else. `kind` SHALL be the string `open` or the string `protected`. An omitted `kind` means `protected`. `null`, any other string (compared exactly, not trimmed or case-folded), a number, a boolean, a list and an object SHALL be 400 `bad_kind` before a signature. A header (including `x-room-kind`), a query parameter, and the path SHALL NOT set or change the kind, including when they disagree with the body.

The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk` on every mint. The file and its directory SHALL be root-owned. The directory SHALL NOT be writable by group or other. The file SHALL NOT be readable or writable by group or other. A failed check SHALL be 503 and SHALL NOT sign. Enabled, host, the token ceiling and the open-room switch SHALL be read from `/etc/mjolnir-relay/relay.env` on every mint, not from the controller environment. A missing env file, a missing key, `MJOLNIR_RELAY_ENABLED` other than `true`, or an unset `MJOLNIR_RELAY_HOST` SHALL be 503 and SHALL NOT sign. The ceiling SHALL be `MJOLNIR_RELAY_TOKEN_MAX_TTL` in that file, or 3600 when the line is absent. A ceiling line that is not a positive integer SHALL be 503 and SHALL NOT sign. A mint with `kind` `open` SHALL be 503 `open_rooms_unavailable` and SHALL NOT sign unless that file sets `MJOLNIR_RELAY_OPEN_ROOMS=true`.

The token SHALL be EdDSA, SHALL carry the signing key's `kid`, SHALL set integer `iat` and `exp`, SHALL set a `jti` of 22 base64url characters, and SHALL NOT set `aud` or any claim outside the moq-auth set `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub` and the claim `kind`. A token for an open room SHALL carry `"kind": "open"`. A token for a protected room SHALL carry no `kind` claim, so that its claim names and root are those of a token minted before `kind` existed. The default life SHALL be the lower of the ceiling and 3600 seconds. An omitted `ttl` means that default. Resubscribe-on-announce in the client is a precondition for a call longer than one token, and for returning to a short default. `ttl` SHALL be a JSON integer in the body. It SHALL be honored when it is greater than zero and at most the ceiling. `0`, a negative, a value above the ceiling, a string, and a float SHALL be 400 before a signature. The response SHALL be JSON with keys `token`, `expires`, `root`, `publish`, `subscribe`, `relay_host`, and `kind`, and SHALL set `Cache-Control: no-store`. `kind` SHALL be `open` or `protected` and SHALL always be present. It SHALL NOT contain a private key. The mint SHALL log the caller's `sub`, the owner, the room, the validated kind, the participant label, the `jti`, and `exp`, and SHALL NOT log the token or the raw request value of `kind`.

The owner check SHALL NOT trim. Legacy hex SHALL match `\A[0-9a-f]{64}\z`. The `sub` SHALL equal its canonical re-encode. A sites token is refused with 403 before a signature. A capability principal and a ceremony principal do not reach this route: the auth plug answers 401. The mint module, if those principals are passed in, returns 403.

The checks run in this order, and the first failure answers: scope `relay:join` (403 `insufficient_scope`), user principal (403 `forbidden`), room and participant segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), `kind` (400 `bad_kind`), env file, ceiling line, enabled and host (503 `relay_unavailable`), the open-room switch when `kind` is `open` (503 `open_rooms_unavailable`), `ttl` range (400 `bad_ttl`), owner (403 `forbidden`), key file mode and key (503 `relay_unavailable`), room record (409 `room_kind_conflict`, or 503 `relay_unavailable` when the record cannot be read or written). A `sub` that is not an owner therefore gets 503 while the relay is not configured. A bad `kind` gets 400 whether or not the relay is configured.

#### Scenario: Authorized mint
- GIVEN a user with `relay:join` and a canonical `sub`
- WHEN they mint for a room and a participant whose segments match the path rule, with no `ttl` and no `kind`
- THEN the response token is signed by the current mint key and carries that key's `kid`
- AND its root is `t/<that sub>/<room>`
- AND the token's claim names are exactly `exp`, `iat`, `jti`, `publish`, `root`, `subscribe`
- AND the response `kind` is `protected`
- AND its life is the lower of the ceiling and 3600 seconds (3600 when the ceiling line is absent)
- AND `x-owner-id`, if sent, is not the owner in the root

#### Scenario: Open room mint
- GIVEN `MJOLNIR_RELAY_OPEN_ROOMS=true` and a user with `relay:join`
- WHEN they mint for room R and label P with body `{"kind":"open"}`
- THEN the token root is `t/<that sub>/R`, publish is `P/**` and subscribe is `**`
- AND the token carries `"kind": "open"` and no other claim beyond a protected token's
- AND the response `kind` is `open`

#### Scenario: Open rooms switched off
- GIVEN the env file without `MJOLNIR_RELAY_OPEN_ROOMS=true`
- WHEN a user mints with `{"kind":"open"}`
- THEN the response is 503 `open_rooms_unavailable`
- AND no token is signed and no room record is written
- AND a mint with no `kind` or with `{"kind":"protected"}` still succeeds

#### Scenario: Bad kind
- GIVEN a user with `relay:join`, with the relay configured and, separately, with the env file missing
- WHEN they mint with `kind` set to `"Open"`, `"open "`, `""`, `null`, `1`, `true`, `["open"]` or `{}`
- THEN the response is 400 `bad_kind` in both configurations
- AND no token is signed

#### Scenario: Kind outside the body
- GIVEN a user with `relay:join` and open rooms switched on
- WHEN they mint with body `{"kind":"protected"}` and header `x-room-kind: open` and query `?kind=open`, and again with no body `kind` and that header and query
- THEN each token carries no `kind` claim and each response `kind` is `protected`
- AND with body `{"kind":"open"}` and header `x-room-kind: protected` and query `?kind=protected`, the response `kind` is `open`
- AND each log line names only the validated kind

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

## ADDED Requirements

### Requirement: The relay reads the room kind claim
The relay SHALL read a room token's kind from its top-level `kind` claim after verifying the token's signature. An absent `kind` SHALL mean protected. `"open"` SHALL mean open. `"protected"` SHALL mean protected. Any other value SHALL be refused. The relay SHALL keep refusing every other claim outside the pinned moq-auth wire format, a payload with a repeated member, and a payload that is not a JSON object. It SHALL require a `kid` naming a key in the relay key file, an `alg` equal to that key's algorithm, and a key that permits verification and has no scope. It SHALL apply the expiry, not-before, issue-time, lifetime, root and grant rules it applies today. WebTransport and Iroh admission SHALL use the same verifier. A Mjolnir component that decides by kind SHALL use that verifier (`room_token::verify` in `native/mjolnir_relay`).

The relay SHALL admit sessions of both kinds under the same rules. It cannot tell whether a publish comes from a WebRTC bridge, and it SHALL NOT consult the controller's room record. The kind is the owner's declaration: `protected` does not prove that clients encrypt, and `open` does not stop a client from encrypting. Isolation between rooms is the root rule's, and it holds for room-mint tokens. A token rooted at `t/<owner>` reaches every room of that owner whatever its kind; the mint never issues one.

#### Scenario: Token minted before this change
- GIVEN a token minted by the controller before `kind` existed, rooted at `t/<owner>/R`, verified at a fixed time inside its life
- WHEN the relay verifies it on WebTransport and on Iroh
- THEN it is admitted as before
- AND its kind is protected

#### Scenario: Open token
- GIVEN a token minted with `"kind": "open"` for label P in room R
- WHEN a WebTransport client and an Iroh client present it at the room root
- THEN both are admitted with the same grant a protected token for P would have
- AND a subscriber of R with an open token receives P's broadcast

#### Scenario: Malformed kind
- GIVEN correctly signed tokens whose `kind` is `"OPEN"`, `"open "`, `1`, `null` or `["open"]`, or that repeat `kind`
- WHEN each is presented
- THEN each session is refused

#### Scenario: Other unknown claim
- GIVEN a correctly signed token with `"kind": "open"` and another claim `foo`
- WHEN it is presented
- THEN the session is refused

#### Scenario: Expiry under a controlled clock
- GIVEN an open token with `exp` = T and a clock installed so that signature verification and the relay profile both read it
- WHEN it is verified at T−1 and at T
- THEN it is admitted at T−1 and refused at T

### Requirement: One room name has one kind
The controller SHALL keep one room-kind record per `(owner, room)` in `/var/lib/mjolnir/relay-rooms/`, a root-owned directory with no access for group or other, holding files with no access for group or other. A record SHALL hold the owner, the room, the kind, its creation time, and the latest `exp` of any token minted for that room (`last_exp`). A room SHALL be live while `last_exp` is in the future.

The mint SHALL decide the record after every other check and before signing, in one serialising process. With no record, it SHALL create one with the requested kind. With a live record of the same kind, it SHALL raise `last_exp` to the new token's `exp` when that is later. With a live record of the other kind, it SHALL answer 409 `room_kind_conflict`, write nothing and sign nothing. With a record whose `last_exp` has passed, it SHALL apply the reuse rule the owner decides (ASK in `tasks.md`; the recommendation is to replace the record). A record that cannot be read or parsed, or a write that does not complete, SHALL be 503 `relay_unavailable` with nothing signed. Each write SHALL go to a temporary file, be fsynced, be renamed over the record, and fsync the directory. Records SHALL survive a controller restart and a hot cutover unchanged. Two concurrent first mints of different kinds for one room SHALL produce exactly one record, and the loser SHALL get 409.

#### Scenario: First mint records the kind
- GIVEN no record for owner A, room R
- WHEN A mints for R with `{"kind":"open"}` (open rooms on)
- THEN a record `open` exists for (A, R) with `last_exp` equal to the token's `exp`

#### Scenario: Conflicting mint
- GIVEN a live record `open` for (A, R)
- WHEN A mints for R with no `kind`, or with `{"kind":"protected"}`
- THEN the response is 409 `room_kind_conflict`
- AND no token is signed and the record is byte-identical

#### Scenario: Renewal of the same kind
- GIVEN a live record `protected` for (A, R)
- WHEN A mints for R with no `kind` and a later `exp`
- THEN the token is issued and the record's `last_exp` is that later `exp`

#### Scenario: Concurrent first mints
- GIVEN no record for (A, R)
- WHEN two mints for R, one `open` and one `protected`, arrive at the same time
- THEN exactly one succeeds, the other is 409, and the record holds the winner's kind

#### Scenario: Restart
- GIVEN a live record `open` for (A, R)
- WHEN the controller restarts, or a hot cutover loads new code
- THEN a mint for R with no `kind` is still 409

#### Scenario: Unreadable record
- GIVEN a record file for (A, R) that does not parse
- WHEN A mints for R
- THEN the response is 503 `relay_unavailable` and no token is signed

### Requirement: Open rooms are issued only after every verifier reads the claim
An open token SHALL NOT be issued until every relay that the host's tokens reach verifies the `kind` claim. The switch is `MJOLNIR_RELAY_OPEN_ROOMS=true` in `/etc/mjolnir-relay/relay.env`. The operator sets it only after the updated relay is confirmed on that host. Protected tokens SHALL carry no `kind` claim, so they verify on a relay with or without the claim reader. Before a relay or controller rollback, the operator SHALL unset the switch and wait out the token ceiling. The controller's response SHALL always carry `kind`, so a client can tell an old controller (no `kind`) from a refusal of the kind it asked for.

#### Scenario: Old relay and an open token
- GIVEN the relay verifier at the commit running on production before this change
- WHEN it is given a token with `"kind": "open"` or `"kind": "protected"`
- THEN the session is refused
- AND a token with no `kind` is admitted

#### Scenario: Old controller asked for open
- GIVEN the controller as it is before this change
- WHEN a client mints with `{"kind":"open"}`
- THEN the response has no `kind` key and the token carries no `kind` claim
