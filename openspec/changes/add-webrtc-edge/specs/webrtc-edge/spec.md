## ADDED Requirements

### Requirement: One relay connection per exact token
The gateway SHALL keep at most one relay connection for a given bearer byte string. It SHALL NOT share that connection with any other bearer. Each WHIP, WHEP, and admission request SHALL run `assess` on the current key snapshot even when the connection already exists. A refused assessment SHALL NOT open a connection and SHALL NOT use an existing one. The last session to release the connection SHALL close it. Token expiry or relay closure SHALL close that connection and every WebRTC session bound to it, and SHALL NOT close another token's sessions.

#### Scenario: Two legs, one connection
- GIVEN an admitted WHIP session for a token
- WHEN WHEP is admitted for the same token bytes
- THEN both legs use one relay connection, and a second token's WHEP uses a different connection

#### Scenario: Existing connection is not a waiver
- GIVEN a live connection for a token
- WHEN a new request for that token fails `assess` because admissions are closed
- THEN the status is `403` and no new session id is registered

### Requirement: Admission finishes before relay I/O or SDP
The gateway SHALL authenticate the bearer with `assess` using `key_file_trusted` and `load_verify_keys` constraints and the configured max TTL, then require an open root `t/<owner>/~open/<room>`, a matching URL room on media routes (the expected-root header supplies context for /admit), a byte-exact `X-Mjolnir-Root`, and a grant match for the parsed broadcast. It SHALL reject a wide `t/<owner>` root. `POST /admit` SHALL run this sequence, return `Cache-Control: no-store`, and SHALL NOT dial the relay. WHIP and WHEP SHALL run it again and SHALL NOT trust a previous `/admit` body. The relay TLS certificate SHALL be verified. Setup SHALL be bounded by token expiry and five seconds, SHALL be raced against relay closure, and SHALL recheck expiry immediately before `201`. Any refusal, timeout, or answer-delivery failure SHALL drop the unrun response and release only that attempt's hold.

#### Scenario: Preflight does not dial
- GIVEN a valid open token and a matching `X-Mjolnir-Root`
- WHEN the client POSTs `/admit`
- THEN the status is 200, the body names that root, and the relay dial counter is unchanged

#### Scenario: Expiry during catalog wait
- GIVEN a WHEP setup whose catalog wait outlasts `exp`
- WHEN the wait ends
- THEN the status is not 201, no session id remains, and all legs of the expired token have stopped and other-token legs are unaffected

#### Scenario: Protected root
- GIVEN a bearer whose assessed root has no `~open` segment
- WHEN the client POSTs WHIP
- THEN the status is `403` with `error` `room_not_open` and the dial counter is unchanged

### Requirement: DELETE and errors are token-scoped
`DELETE /session/<id>` SHALL succeed with `204` only for the bearer that admitted that id, including repeats retained until exp+30s; thereafter the id is unknown. Another bearer SHALL receive `403` and SHALL NOT change the session. An unknown id SHALL receive `404`. The gateway SHALL NOT drop a different session id as part of that DELETE. Error responses SHALL use the codes in the design table. The broadcast path SHALL be parsed once, rejecting encoded slashes and dot segments, and that parsed string SHALL be the path matched to the grant and passed to moq.

#### Scenario: Repeat DELETE
- GIVEN a session id admitted by token T
- WHEN T DELETEs it twice
- THEN both responses are `204` and a different token's DELETE of that id was `403` while it existed

#### Scenario: Encoded slash
- GIVEN a broadcast path containing `%2f`
- WHEN the request is admitted or refused
- THEN the path compared to the grant does not contain a slash that came from that escape

### Requirement: A video offer is not left running as silent audio
If the offer contains video and the built answer contains no usable accepted video section (port zero or inactive is rejected), the gateway SHALL drop the unrun response and return `409` `codec_unavailable`. If WHEP cannot obtain a catalog or a rendition before the setup deadline, it SHALL drop the unrun response and return `409` `not_started`. WHIP SHALL NOT require a pre-existing catalog.

#### Scenario: Codec miss
- GIVEN an offer with video and an answer the pin would have returned with video rejected
- WHEN WHEP handles it
- THEN the status is `409`, no session id is registered, and `run` was not called

### Requirement: The unit stays off until a separate deploy approval
A relay deploy without the rtc flag SHALL NOT install `mjolnir-rtc`. This requirement does not authorize that flag.

#### Scenario: Default deploy
- GIVEN a relay deploy without the rtc flag
- WHEN the host is inspected
- THEN `mjolnir-rtc` is not running

### Requirement: Complete preflight and bounded owned setup
/admit SHALL validate explicit operation and canonical broadcast and complete every admission/grant/expiry check before 200, without dialing. Setup deadline SHALL begin before pool acquisition/dial. Pool reservations SHALL be single-flight and released exactly once on all terminal paths, including response delivery failure and runner completion. Expiry SHALL stop all same-token legs; earlier candidate timeout SHALL preserve incumbents. Catalog deadline before expiry returns not_started, dial/other deadline setup_failed, and expiry bad_token. Parser and resource race tests SHALL cover design D8.
