## ADDED Requirements

### Requirement: Every keyframe request on a WHIP video line passes one cooldown
When the keyframe policy is enabled for a WHIP ingest, every PLI the ingest sends on a negotiated video line SHALL pass one per-line gate, including the requests the pinned crate sends while a line has no keyframe and for a deferred timeline step. The floor SHALL default to 1 second, and `whip::accept` SHALL refuse an enabled policy whose floor or period is zero. The gate SHALL send only when at least the floor has passed since the last PLI the line actually sent, on a monotonic clock; a PLI counts as sent only when the line's writer existed and accepted it. A request inside the floor SHALL set one held request per line, whatever the number of causes or callers, to be sent when the floor ends. A keyframe received on the line, the first included, SHALL cancel a held request. The gate SHALL send only to a line that negotiated PLI and has a current receive stream; otherwise the request SHALL stay held, the last-sent time SHALL NOT move, the expired deadline SHALL be disarmed until a receive-stream transition on that line or a strictly future deadline from another cause, and the session SHALL NOT end because of it. When the policy is disabled, the ingest SHALL behave as the pinned `moq-webrtc` does.

#### Scenario: Overlapping causes send one request
- GIVEN an enabled line that sent a PLI at time t
- WHEN a startup request, a period deadline, a loss frame and two viewer requests all arrive between t and t + 1 second, and no keyframe arrives
- THEN the line sends exactly one PLI, at t + 1 second, tagged with all four causes

#### Scenario: Pinned paths are inside the cooldown
- GIVEN an enabled line that sent a viewer-cause PLI at time t
- WHEN a deferred timeline step asks for a keyframe at t + 0.3 seconds
- THEN no PLI is sent before t + 1 second

#### Scenario: A keyframe answers a held request
- GIVEN an enabled line that sent a PLI at time t and holds a request made at t + 0.5 seconds
- WHEN a keyframe arrives at t + 0.7 seconds
- THEN no PLI is sent at t + 1 second

#### Scenario: An unanswered request does not spin
- GIVEN an enabled line with a 2 second period whose last keyframe was at time 0 and which sent a period PLI at 2 seconds that the publisher ignored
- WHEN no keyframe arrives
- THEN the next period PLI is sent at 4 seconds, and none between

#### Scenario: A timer before the receive stream exists
- GIVEN an enabled line whose period deadline passes before any RTP has arrived on it
- WHEN 10 seconds elapse with no RTP
- THEN no PLI is sent, the request stays held, the line's timer does not fire again in that time, the session keeps running, and `last_sent` is unset

#### Scenario: A held request is released or cancelled by the first frame
- GIVEN an enabled line holding a request because no receive stream existed
- WHEN its first frame arrives and is a delta, or in another run is a keyframe
- THEN the delta releases one PLI at once (the floor allows, nothing was sent), and the keyframe cancels the held request with no PLI

#### Scenario: A writer that refuses does not consume the floor
- GIVEN an enabled line whose writer is absent or returns an error for a request at time t
- WHEN a receive stream appears at t + 0.2 seconds
- THEN a PLI is sent at t + 0.2 seconds, not held until t + 1 second

#### Scenario: Enabling the policy from defaults keeps a one second floor
- GIVEN `Keyframes { enabled: true, ..Default::default() }`
- WHEN two viewer requests arrive 100 milliseconds apart
- THEN the second PLI is sent 1 second after the first

#### Scenario: A zero interval is refused
- GIVEN an enabled policy with a zero floor, and in another case a zero period
- WHEN `whip::accept` runs
- THEN it returns `Error::InvalidKeyframes` and no session starts

#### Scenario: Disabled policy is the pinned behaviour
- GIVEN `whip::Request::new` with no keyframe settings
- WHEN a WHIP session runs, starts with no keyframe, takes a timeline step, receives non-contiguous frames, and is asked by a requester
- THEN it sends exactly the PLIs the pinned crate sends, and its `Response::keyframes()` requester returns `Ignored` for every request

### Requirement: A WHIP ingest asks for keyframes on a period and after loss
When the policy is enabled with a period, a video line SHALL request a keyframe once the period has passed since the later of its last keyframe and its last sent PLI. When the policy is enabled with loss requests on, a non-keyframe video frame that str0m marks as not contiguous SHALL request a keyframe. The loss cause SHALL NOT change forwarding: the pinned admission decision SHALL still decide whether that frame is forwarded or dropped. Both requests SHALL pass the per-line cooldown. The period is a request cadence; the ingest SHALL NOT treat an unanswered request as an error.

#### Scenario: Period on a publisher that never volunteers keyframes
- GIVEN an enabled line with a 2 second period, whose last keyframe arrived at time 0
- WHEN no keyframe arrives
- THEN the line sends a period PLI at 2 seconds

#### Scenario: No period request to a publisher that keeps its own GOP
- GIVEN an enabled line with a 2 second period that receives a keyframe every second
- WHEN 20 seconds pass with no other cause
- THEN the line sends no period PLI

#### Scenario: Usable discontinuous delta
- GIVEN an enabled line with loss requests on, past its first keyframe
- WHEN a non-keyframe frame arrives with `contiguous == false` and a media time after the line's last keyframe
- THEN the line requests a keyframe and the frame is forwarded, as the pinned admission forwards it

#### Scenario: Ineligible discontinuous delta
- GIVEN an enabled line with loss requests on
- WHEN a non-keyframe frame with `contiguous == false` arrives on a line that has had no keyframe, and in another case with a media time before the line's last keyframe
- THEN the line requests a keyframe (in the first case one PLI tagged with both the startup and loss causes) and the frame is dropped, as the pinned admission drops it

### Requirement: A WHIP ingest asks for a keyframe when a join wants a group past the newest
When the policy is enabled with a refresh ratio, each WHIP video track SHALL carry `track::Info::refresh` with that ratio, and the ingest SHALL request a keyframe on that line when the track's `Demand::wanted` becomes a group number greater than the largest group written. No other demand change SHALL request: not a reader count rising from zero, not a request for group 0 on a track with no group, and not the observer's first reading. A first reader SHALL be judged by the ratio like any later reader. The request SHALL pass the per-line cooldown.

#### Scenario: Late join over the ratio
- GIVEN an enabled track with ratio 4 whose newest group's deltas exceed four times its keyframe
- WHEN a new reader subscribes at the live edge
- THEN the line requests a keyframe

#### Scenario: Join under the ratio, first or later
- GIVEN an enabled track with ratio 4 whose newest group's deltas are under four times its keyframe
- WHEN the first reader subscribes, and later a second
- THEN neither join requests a keyframe

#### Scenario: Empty track
- GIVEN an enabled track with no group written
- WHEN a reader subscribes
- THEN the join cause sends nothing, and the startup request covers the line

### Requirement: A WHEP play stays on the viewer's relay token
The gateway SHALL open each WHEP play as a relay subscribe session with that viewer's own token, and SHALL NOT supply WHEP an in-process publisher origin. The gateway SHALL NOT forward a viewer's PLI or FIR to a WHIP session. A viewer's loss recovery waits for the ingest cadence in "A WHIP ingest asks for keyframes on a period and after loss". The carried patch SHALL NOT add a WHEP requester, a pairing table, or a local-playback source.

#### Scenario: Viewer PLI does not reach the publisher
- GIVEN alice publishes over WHIP through the relay and bob plays that broadcast over WHEP through the relay with his own token
- WHEN bob's browser sends a PLI
- THEN alice's session receives no viewer-cause request

#### Scenario: No local origin
- GIVEN a WHEP accept for a broadcast that a WHIP session on the same process is publishing
- WHEN the edge builds the WHEP source
- THEN the source is the relay session opened with the viewer's token

### Requirement: The keyframe patch is carried without moving the moq pin
The edge's `moq-webrtc` SHALL be the vendored copy at `native/vendor/moq-webrtc/`: upstream `rs/moq-webrtc` at `4a6f522483168ace392718d68b58a402533c897d`, with only the packaging differences listed in its `VENDOR.md` and the patch in its `patches/` directory. The copy SHALL keep upstream's `LICENSE-MIT` (Copyright (c) 2023 Luke Curley) and `LICENSE-APACHE` unmodified, SHALL mark every file the patch or the packaging changed with a modification notice, and SHALL record in `VENDOR.md` who authorised the outbound licence. Its manifest SHALL keep every feature and default-feature setting the crate inherited from the moq workspace at the pin. Only the consuming workspace's root manifest SHALL patch `moq-webrtc` to that path, and every other moq crate SHALL resolve from `git+https://github.com/moq-dev/moq?rev=4a6f52248`, one copy each. `native/mjolnir_relay/Cargo.toml` and `native/mjolnir_relay/Cargo.lock` SHALL be byte-identical before and after this change.

#### Scenario: Vendored tree matches upstream plus the documented differences
- GIVEN `native/vendor/moq-webrtc/`
- WHEN `scripts/check-vendored-moq-webrtc.sh` reverses the patch and compares the tree, the licence files and the manifest to upstream at `4a6f522`
- THEN `src/` and the other upstream files are identical, the licence files equal the moq root's, and the manifest differs only as `VENDOR.md` lists

#### Scenario: One moq-net in the consumer
- GIVEN the harness workspace with the `[patch]` line and its committed lock
- WHEN `cargo metadata --locked` runs there
- THEN `moq-webrtc` has a path package id under `native/vendor/moq-webrtc`, every other moq package id names `git+https://github.com/moq-dev/moq?rev=4a6f52248#4a6f522483168ace392718d68b58a402533c897d`, no moq package appears twice, and cargo prints no unused-patch warning

#### Scenario: Relay untouched
- GIVEN the commit before this change and the commit that lands it
- WHEN the relay's manifest and lockfile hashes are compared and `cargo metadata --locked` runs in the relay
- THEN the hashes are equal and the metadata command succeeds
