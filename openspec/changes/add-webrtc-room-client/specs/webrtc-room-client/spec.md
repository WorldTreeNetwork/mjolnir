## ADDED Requirements

### Requirement: The client checks admission before media
The client SHALL verify the mint token with the relay JWKS and SHALL compare the invitation's expected full root, the asked kind, the mint `root` and `kind`, and that verified root before it calls `getUserMedia`, creates an `RTCPeerConnection`, imports a media key, or POSTs WHIP or WHEP. The comparison SHALL follow `Mjolnir.Relay.RoomJoin`: the expected root, the response root, and the verified root are equal byte for byte; an explicit open ask SHALL fail when the root is protected or the mint omits `kind` on a non-open root. A failed check SHALL tear nothing down that it did not start, and SHALL NOT start the camera.

#### Scenario: Old mint
- GIVEN an invitation whose expected root is `t/<owner>/~open/<room>` and a mint body whose root is `t/<owner>/<room>` and whose kind is absent
- WHEN `join` runs
- THEN the result is `open_refused` and `getUserMedia` was not called

#### Scenario: Mismatched invitation
- GIVEN a verified open root and an expected root that is not equal to it
- WHEN `join` runs
- THEN the result is `unexpected_root` and no WHIP request is sent

#### Scenario: Matching open token
- GIVEN expected root, mint root, mint kind `open`, and the verified root are the same open root
- WHEN `join` runs
- THEN the host-readable notice is shown and only then is the camera requested

### Requirement: Replacement and renewal use the same check
`replace` and `renew` SHALL run the same verification and comparison on the new credential. On failure they SHALL leave existing PeerConnections running. On success they SHALL establish the new WHIP and WHEP sessions before deleting the previous session ids. The client SHALL call `teardown` at token `exp`, stopping tracks and closing every PeerConnection.

#### Scenario: Bad renewal
- GIVEN a live session and a renewal mint that fails verification
- WHEN `renew` returns
- THEN the previous PeerConnections are still open

#### Scenario: Expiry
- GIVEN a live session
- WHEN `exp` is reached
- THEN tracks are stopped and every PeerConnection is closed

### Requirement: The open room is described as host-readable
Before media starts, the page SHALL show that the room is open and that the host can read the media. The page SHALL NOT describe the room as end-to-end encrypted.

#### Scenario: Notice
- GIVEN a successful open join
- WHEN the camera prompt is shown
- THEN the host-readable notice is already visible

### Requirement: A roster is not claimed here
Until `mjolnir-rurh.14` lands, the page SHALL play only broadcast paths named by the invitation. It SHALL NOT present a live roster. Shipping self-view alone SHALL NOT satisfy this node's acceptance.

#### Scenario: No named peer
- GIVEN an invitation with no other broadcast path
- WHEN join succeeds
- THEN the page shows the local preview and no other participant
