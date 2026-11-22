## ADDED Requirements

### Requirement: The controller mints a room token
The Mjolnir API SHALL mint a moq-auth JWT for one participant in one room. The route SHALL be `POST /api/relay/rooms/:room/participants/:participant/token`. The caller SHALL present scope `relay:join`. The room owner SHALL be the canonical owner in `x-owner-id`. A missing or non-canonical header SHALL be refused with 400 before a signature. A body field `owner_id` SHALL be ignored. A caller without `relay:join`, including a sites service token and the operator socket, SHALL be refused with 403. The signing key SHALL be read from `/var/lib/mjolnir/relay-mint/current.jwk`, mode `0600`, owner root. The API SHALL NOT accept a private key or a public key on any route. The response SHALL be the token, its expiry, its root, its publish pattern, its subscribe pattern, and the configured `:relay_host`. It SHALL NOT contain a private key.

#### Scenario: Authorized mint
- GIVEN a caller with `relay:join` and a canonical `x-owner-id`
- WHEN they mint for a room and a participant whose segments match the path rule
- THEN the response token is signed by the current mint key
- AND its root is `t/<that owner>/<room>`
- AND its life from issue to expiry is at most `:relay_token_max_ttl`

#### Scenario: Wrong caller
- GIVEN a caller without `relay:join`
- WHEN they call the mint
- THEN the response is 403 and no token is signed

### Requirement: A room path binds publish to one participant
A room path SHALL be `t/<owner id>/<room>/<participant>/<rest>`. `<room>` and `<participant>` SHALL each be one segment matching `[A-Za-z0-9_-]{1,64}` and SHALL NOT be `mjolnir-nopublish`. The token root SHALL be `t/<owner id>/<room>`. The subscribe pattern SHALL cover that root and every path under it. The publish pattern SHALL cover only `t/<owner id>/<room>/<participant>` and every path under it. The relay SHALL refuse a publish outside that publish pattern on WebTransport and on Iroh. A segment that breaks the rule SHALL be refused before a signature.

#### Scenario: Own track
- GIVEN a token minted for participant P in room R
- WHEN a client presents it and publishes `t/<owner>/R/P/track` on WebTransport, and another client does the same on Iroh
- THEN both publishes are admitted
- AND a subscribe of room R on each transport receives that track

#### Scenario: Another participant
- GIVEN a token minted for participant P in room R
- WHEN a client presents it and publishes `t/<owner>/R/Q/track` on WebTransport, and on Iroh
- THEN both publishes are refused

#### Scenario: Another room
- GIVEN a token whose root is `t/<owner>/R`
- WHEN it is presented for a session on `t/<owner>/S` on WebTransport, and on Iroh
- THEN both sessions are refused

#### Scenario: No token
- GIVEN a client with no token
- WHEN it opens a session on a room path on WebTransport, and on Iroh
- THEN both sessions are refused

### Requirement: Expiry ends the session
The relay SHALL close a session when its token expires. The mint SHALL NOT issue a token whose life exceeds `:relay_token_max_ttl`. This capability SHALL NOT replace the token on an open session. A client that still wants the room SHALL mint a new token and open a new session.

#### Scenario: Call longer than the token
- GIVEN an admitted session whose token then reaches `exp`
- WHEN the relay applies that expiry
- THEN the session is closed on the transport it used
- AND a new session with a newly minted token for the same participant is admitted

### Requirement: Rotation revokes a signing key after one token life
An operator rotation, run as root on the controller, SHALL install a new signing key, SHALL publish the new public key and the previous public key together to `/etc/mjolnir-relay/relay-keys.json` by rename, and SHALL sign every new token with the new key only. After `:relay_token_max_ttl` plus 60 seconds the public set SHALL be replaced, by rename, with the new key only, and the previous private key SHALL be deleted. A session already admitted SHALL keep that admission until its token expires, including after the previous public key leaves the file. A new session whose token was signed by a key no longer in the file SHALL be refused. No rotation step SHALL send key material through the gateway user or through an API route.

#### Scenario: Overlap
- GIVEN a token signed by the previous key and a public set that still holds that key
- WHEN a new session presents it before the overlap ends
- THEN the session is admitted

#### Scenario: After the overlap
- GIVEN the public set holds only the new key
- WHEN a new session presents a token signed by the previous key
- THEN the session is refused
- AND a session that was admitted under the previous key before this replacement is still open until that token's expiry
