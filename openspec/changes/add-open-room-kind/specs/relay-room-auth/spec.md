## MODIFIED Requirements

### Requirement: The controller mints a room token for the caller
<!-- base: fe562845ecfd16cb45fb2ad13b6f29ec758aeffa openspec/specs/relay-room-auth/spec.md -->
The Mjolnir API SHALL mint a moq-auth JWT for one participant label in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL be a user principal (`principal_kind == :user`) and SHALL present scope `relay:join`. The operator socket, a sites service token, and any other principal SHALL be refused with 403 before a signature, including when that principal holds `relay:join`.

The owner SHALL be the caller's verified `sub`, resolved as `Mjolnir.Deploy.Owner.resolve/2` resolves a non-operator, so `x-owner-id` is ignored. A canonical base58 `sub` SHALL be used as-is. A legacy 64-hex `sub` SHALL be re-encoded to canonical base58. Any other `sub` SHALL be refused with 403 before a signature. A body field `owner_id` SHALL be ignored. A user who sends another owner's id in the header SHALL NOT receive a token rooted at that other owner.

The room's kind SHALL come from the JSON body field `kind` and from nowhere else. `kind` SHALL be the string `open` or the string `protected`. An omitted `kind` means `protected`. `null`, any other string (compared exactly, not trimmed or case-folded), a number, a boolean, a list and an object SHALL be 400 `bad_kind` before a signature. A header (including `x-room-kind`), a query parameter, and the path SHALL NOT set or change the kind, including when they disagree with the body.

The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk` on every mint. The file and its directory SHALL be root-owned. The directory SHALL NOT be writable by group or other. The file SHALL NOT be readable or writable by group or other. A failed check SHALL be 503 and SHALL NOT sign. Enabled, host, and the token ceiling SHALL be read from `/etc/mjolnir-relay/relay.env` on every mint, not from the controller environment. A missing env file, a missing key, `MJOLNIR_RELAY_ENABLED` other than `true`, or an unset `MJOLNIR_RELAY_HOST` SHALL be 503 and SHALL NOT sign. The ceiling SHALL be `MJOLNIR_RELAY_TOKEN_MAX_TTL` in that file, or 3600 when the line is absent. A ceiling line that is not a positive integer SHALL be 503 and SHALL NOT sign.

The token SHALL be EdDSA, SHALL carry the signing key's `kid`, SHALL set integer `iat` and `exp`, SHALL set a `jti` of 22 base64url characters, and SHALL NOT set `aud`, `kind`, or any claim outside the moq-auth set `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf`, `jti`, `iss`, `sub`. A protected room SHALL be rooted at `t/<owner>/<room>`. An open room SHALL be rooted at `t/<owner>/~open/<room>`, where `~open` is one literal path segment. The default life SHALL be the lower of the ceiling and 3600 seconds. An omitted `ttl` means that default. `ttl` SHALL be a JSON integer in the body. It SHALL be honored when it is greater than zero and at most the ceiling. `0`, a negative, a value above the ceiling, a string, and a float SHALL be 400 before a signature. The response SHALL be JSON with keys `token`, `expires`, `root`, `publish`, `subscribe`, `relay_host`, and `kind`, and SHALL set `Cache-Control: no-store`. `kind` SHALL be `open` or `protected` and SHALL always be present. `root` SHALL be the root in the token. The response SHALL NOT contain a private key. The mint SHALL log the caller's `sub`, the owner, the room, the validated kind, the participant label, the `jti`, and `exp`, and SHALL NOT log the token or the raw request value of `kind`.

An open mint and a protected mint for the same owner and room name SHALL both succeed. They SHALL sign different roots. The mint SHALL NOT consult or write a room-kind record.

The owner check SHALL NOT trim. Legacy hex SHALL match `\A[0-9a-f]{64}\z`. The `sub` SHALL equal its canonical re-encode. A sites token is refused with 403 before a signature. A capability principal and a ceremony principal do not reach this route: the auth plug answers 401. The mint module, if those principals are passed in, returns 403.

The checks run in this order, and the first failure answers: scope `relay:join` (403 `insufficient_scope`), user principal (403 `forbidden`), room and participant segments (400 `bad_segment`), `ttl` type (400 `bad_ttl`), `kind` (400 `bad_kind`), env file, ceiling line, enabled and host (503 `relay_unavailable`), `ttl` range (400 `bad_ttl`), owner (403 `forbidden`), key file mode and key (503 `relay_unavailable`). A `sub` that is not an owner therefore gets 503 while the relay is not configured. A bad `kind` gets 400 whether or not the relay is configured.

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
- GIVEN a user with `relay:join`
- WHEN they mint for room R and label P with body `{"kind":"open"}`
- THEN the token root is `t/<that sub>/~open/R`, publish is `P/**` and subscribe is `**`
- AND the token's claim names are exactly `exp`, `iat`, `jti`, `publish`, `root`, `subscribe`
- AND the response `kind` is `open`

#### Scenario: Same name, two roots
- GIVEN a user with `relay:join`
- WHEN they mint room R with `{"kind":"open"}` and again with no `kind`
- THEN both responses succeed
- AND the roots are `t/<owner>/~open/R` and `t/<owner>/R`
- AND no room-kind file is written

#### Scenario: Bad kind
- GIVEN a user with `relay:join`, with the relay configured and, separately, with the env file missing
- WHEN they mint with `kind` set to `"Open"`, `"open "`, `""`, `null`, `1`, `true`, `["open"]` or `{}`
- THEN the response is 400 `bad_kind` in both configurations
- AND no token is signed

#### Scenario: Kind outside the body
- GIVEN a user with `relay:join`
- WHEN they mint with body `{"kind":"protected"}` and header `x-room-kind: open` and query `?kind=open`, and again with no body `kind` and that header and query
- THEN each token root is `t/<owner>/<room>` and each response `kind` is `protected`
- AND with body `{"kind":"open"}` and header `x-room-kind: protected` and query `?kind=protected`, the root is `t/<owner>/~open/<room>` and the response `kind` is `open`
- AND each log line names only the validated kind

#### Scenario: Explicit open against the previous mint
- GIVEN a controller that does not read `kind`
- WHEN a client asked for `{"kind":"open"}` and the response has no `kind` field and a root `t/<owner>/<room>`
- THEN a conforming client SHALL NOT connect, publish, or import a credential
- AND it SHALL surface a join error

#### Scenario: Cross-tenant header
- GIVEN a user whose `sub` is owner A
- WHEN they mint with `x-owner-id` set to owner B
- THEN the token root is under owner A
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

### Requirement: A verified root classifies as open, protected, or invalid
A consumer that needs the room kind SHALL classify the verified token root and SHALL NOT read a `kind` claim. Classification SHALL split that string on the literal character `/` and SHALL NOT percent-decode, trim, case-fold, or normalize it.

The result SHALL be `protected` only when there are exactly three segments, the first is `t`, the second is a canonical 32-byte base58 owner, and the third matches `[A-Za-z0-9_-]{1,64}`. The result SHALL be `open` only when there are exactly four segments, the first is `t`, the second is that owner, the third is exactly `~open`, and the fourth matches that room pattern. Every other string SHALL be `invalid`, including `t/<owner>`, extra segments, empty segments, `.`, `..`, `%7Eopen`, `%257Eopen`, `~Open`, and a non-canonical owner.

The relay SHALL keep its existing admission grammar. This classifier SHALL NOT replace `root_allowed` or grant checks. A WebRTC admission SHALL treat `protected` and `invalid` as not open, including a wide root presented with an open URL. That admission is specified by `add-webrtc-edge`.

#### Scenario: Two roots
- GIVEN verified roots `t/<owner>/standup` and `t/<owner>/~open/standup`
- WHEN each is classified
- THEN the results are `protected` and `open`

#### Scenario: Not open
- GIVEN verified roots `t/<owner>`, `t/<owner>/%7Eopen/standup`, `t/<owner>/%257Eopen/standup`, `t/<owner>/~Open/standup`, and `t/<owner>/~open/standup/extra`
- WHEN each is classified
- THEN each result is `invalid`

#### Scenario: Room alphabet lookalikes
- GIVEN verified roots `t/<owner>/open` and `t/<owner>/_open`
- WHEN each is classified
- THEN each result is `protected`
