## ADDED Requirements

### Requirement: WebRTC admission uses one relay assess and an open root
The gateway SHALL verify the bearer with the relay's `assess` on one key-set snapshot before it dials the relay or writes an SDP answer. It SHALL admit only a root that classifies as open, `t/<owner>/~open/<room>`. It SHALL reject a protected root, a root with no `~open` marker, and a wide `t/<owner>` root with `403 room_not_open`. It SHALL reject a failed assess with `403 bad_token`. It SHALL require `X-Mjolnir-Root` to equal the assessed root byte for byte, and SHALL reject a mismatch with `403 unexpected_root` and a missing header with `400`. It SHALL require the WHIP broadcast to match the publish grant and the WHEP broadcast to match the subscribe grant. The URL room segment SHALL equal the assessed root's room segment and SHALL NOT be used to build a MoQ path.

#### Scenario: Open token is admitted
- GIVEN a bearer whose assessed root is `t/<owner>/~open/<room>`, a matching `X-Mjolnir-Root`, and a broadcast inside the publish grant
- WHEN the client POSTs WHIP
- THEN the gateway opens a relay session with that bearer and returns an SDP answer

#### Scenario: Protected and old mint are refused
- GIVEN a bearer whose assessed root is `t/<owner>/<room>` with no `~open` segment
- WHEN the client POSTs WHIP or WHEP
- THEN the status is `403 room_not_open` and no relay session is opened

#### Scenario: Wide root
- GIVEN a bearer whose assessed root is `t/<owner>` and a URL that contains `~open`
- WHEN the client POSTs WHEP
- THEN the status is `403 room_not_open`

#### Scenario: Expected root
- GIVEN an assessed open root and an `X-Mjolnir-Root` that differs by one character
- WHEN the client POSTs WHIP
- THEN the status is `403 unexpected_root` and no SDP answer is written

### Requirement: Each WebRTC leg uses its own relay session
The gateway SHALL attach WHIP and WHEP only to a relay session opened with the bearer that just passed admission. It SHALL NOT attach WHEP to an in-process publisher origin. It SHALL close the WebRTC task when that relay session closes or when the token's `exp` is reached. It SHALL NOT answer a request whose `exp` has already passed. A replacement POST SHALL leave the previous session running until the new request returns `201`.

#### Scenario: Expiry
- GIVEN an admitted session whose token expires
- WHEN `exp` is reached
- THEN the DTLS association is closed

#### Scenario: Failed renewal
- GIVEN a live session and a renewal POST that assesses as `bad_token`
- WHEN the response is sent
- THEN the live session is still running

### Requirement: A video offer is not answered as silent audio
If the offer contains a video m-line and the catalog's video codecs do not overlap the offer, the gateway SHALL return `409 codec_unavailable` and SHALL NOT start a session. If WHEP finds no catalog, it SHALL return `409 not_started` and SHALL NOT start a session.

#### Scenario: Codec miss
- GIVEN a catalog whose only video codec the browser did not offer
- WHEN WHEP answers
- THEN the status is `409 codec_unavailable` and no PeerConnection is established

### Requirement: The unit is off until a deploy flag installs it
`mjolnir-rtc` SHALL NOT be installed or started by a normal relay deploy. Its media UDP port SHALL be listed in the published-port reserved set when the unit is installed. This requirement does not authorize that install.

#### Scenario: Default deploy
- GIVEN a relay deploy without the rtc flag
- WHEN the host is inspected
- THEN `mjolnir-rtc` is not running and its port is not reserved
