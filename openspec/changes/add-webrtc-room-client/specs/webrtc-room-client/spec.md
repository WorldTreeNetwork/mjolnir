## ADDED Requirements

### Requirement: Admission comes from the configured gateway
The client SHALL send the bearer and the invitation's expected root to `POST /admit` on its configured gateway origin, and SHALL NOT take that origin from the invitation, a query parameter, or `relay_host`. It SHALL compare the expected root, the mint root and kind, and the admitted root in `RoomJoin` order. It SHALL NOT treat caller-supplied JSON as admission. It SHALL NOT call `getUserMedia`, construct an `RTCPeerConnection`, import a content key, or POST WHIP or WHEP until that check succeeds. An open expected root with a protected admitted root SHALL be `unexpected_root`. A protected expected root with ask `open` SHALL be `open_refused`. An open admitted root whose mint omits `kind` SHALL be `kind_mismatch`.

#### Scenario: Old mint
- GIVEN expected root `t/<owner>/~open/<room>` and an admitted root `t/<owner>/<room>`
- WHEN `join` runs
- THEN the result is `unexpected_root` and `getUserMedia` was not called

#### Scenario: Protected invitation
- GIVEN expected root and admitted root are the same protected root and the ask is `open`
- WHEN `join` runs
- THEN the result is `open_refused` and no WHIP request is sent

#### Scenario: Open root missing kind
- GIVEN the admitted root is open and the mint body has no `kind`
- WHEN `join` runs
- THEN the result is `kind_mismatch`

### Requirement: A candidate failure does not destroy the incumbent
`replace` and `renew` SHALL build a new generation. They SHALL DELETE previous session ids only after the new WHIP has committed. If the new WHIP fails, they SHALL drop only the new generation's tracks, PeerConnections, and timers. An expiry timer SHALL close only the generation that armed it. `teardown` SHALL DELETE each owned session id with the bearer that admitted it, then close that generation's PeerConnections and stop tracks whose refcount is zero. A callback from an older generation SHALL NOT attach media or DELETE a newer id. `renew` SHALL NOT mint a token.

#### Scenario: Partial renewal
- GIVEN a live generation and a renewal whose WHIP returns `403`
- WHEN `renew` finishes
- THEN the live generation's PeerConnections are open and the new generation has no session id

#### Scenario: Stale camera
- GIVEN generation 1's `getUserMedia` resolves after generation 2 has committed
- WHEN the resolution is delivered
- THEN generation 2's PeerConnections are unchanged and generation 1's tracks are stopped

### Requirement: Named peers retry without a roster
The page SHALL play only paths on the invitation, at most seven, each a relative broadcast path. `409 not_started` SHALL leave that tile empty and retry under the invitation's minimum one-second backoff. `codec_unavailable` and `403` on that peer SHALL NOT retry. WHIP `201` and a successful remote description SHALL commit the join even while a peer is still `not_started`. If a playing peer's connection ends before expiry, the page SHALL retry that path and SHALL NOT claim the relay follows a replaced publisher. The host-readable notice SHALL be visible before the camera prompt. The page SHALL NOT say the room is end-to-end encrypted.

#### Scenario: Peer not started
- GIVEN WHIP committed and the named peer returns `409 not_started`
- WHEN the join returns
- THEN the local preview is up, the peer tile is empty, and a retry is scheduled no sooner than `retryMs`

#### Scenario: Notice
- GIVEN a successful `/admit` for an open room
- WHEN the camera prompt is shown
- THEN the host-readable notice is already visible

### Requirement: This slice does not finish the node
A passing named-peer slice SHALL NOT close `mjolnir-rurh.15`. Roster, Safari-on-phone, three-network, and eight-PeerConnection proofs remain open.

#### Scenario: Self-view only
- GIVEN an invitation with no peer path and a green local WHIP
- WHEN the slice is recorded
- THEN the bead stays open
