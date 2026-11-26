## ADDED Requirements

### Requirement: A WHIP ingest asks for a keyframe on a period
The edge SHALL configure each WHIP ingest with a keyframe period of 2 seconds. A video line that negotiated PLI and has received no keyframe for the period SHALL send its publisher one PLI, subject to the throttle. The period SHALL be measured from the last keyframe received on the line, so a publisher that sends keyframes at least that often receives no periodic PLI. With no period configured (the crate default), the ingest SHALL behave as the pinned `moq-webrtc` does.

#### Scenario: A browser publisher with no GOP schedule
- GIVEN Chromium publishes VP8 over WHIP to the edge and sends a keyframe only when asked
- WHEN the line has received no keyframe for 2 seconds
- THEN the edge sends one PLI on that line
- AND the publisher's `keyFramesEncoded` rises about every 2 seconds while nothing else asks

#### Scenario: A publisher that already sends keyframes
- GIVEN a WHIP publisher that sends a keyframe every 1 second on its own
- WHEN 20 seconds pass with no reader joining and no loss
- THEN the edge sends no periodic PLI on that line

#### Scenario: Crate default is unchanged
- GIVEN `whip::Request::new` with no keyframe settings
- WHEN a WHIP session runs for 20 seconds after its first keyframe
- THEN the ingest sends no PLI beyond those the pinned crate sends (first keyframe and timeline step)

### Requirement: A WHIP ingest asks for a keyframe when a reader's join wants a new group
The edge SHALL publish each WHIP video track with `track::Info::refresh` set to ratio 4. When the track's `Demand::wanted` moves past the largest group written, or goes from no reader to a reader, the ingest SHALL send its publisher one PLI on that line, subject to the throttle. A join that moq-net judges under the ratio SHALL cause no PLI.

#### Scenario: Late in-process join of a long group
- GIVEN a WHIP video track whose newest group holds deltas larger than four times its keyframe
- WHEN a new reader subscribes to the track at the live edge
- THEN the ingest sends one PLI on that line
- AND the next group starts at the keyframe that answers it

#### Scenario: Early join
- GIVEN a WHIP video track whose newest group's deltas are under four times its keyframe
- WHEN a new reader subscribes at the live edge
- THEN the ingest sends no PLI for that join

### Requirement: A WHIP ingest asks for a keyframe after unrecoverable loss
The edge SHALL configure each WHIP ingest to send one PLI, subject to the throttle, when a video frame arrives that str0m marks as not contiguous with the previous frame and that is not a keyframe. Frames SHALL still be forwarded as the pinned crate forwards them.

#### Scenario: Burst on the publisher's uplink
- GIVEN Chromium publishes over WHIP and a MoQ reader plays the broadcast
- WHEN everything from the publisher to the edge is dropped for 1.5 seconds
- THEN the edge sends a PLI when frames resume
- AND the MoQ reader receives a new group starting with a keyframe within 1.2 seconds after the burst ends

### Requirement: A WHEP viewer's keyframe request reaches a same-edge WHIP source
When a WHEP session on the edge plays a broadcast that a WHIP session on the same edge publishes, under the same verified token root, the edge SHALL pass that WHIP session's keyframe requester to the WHEP session. A PLI or FIR the viewer sends SHALL become one PLI request to the WHIP ingest, subject to the throttle. A WHEP session SHALL NOT receive a requester for a broadcast under another root. A WHEP session of a broadcast with no WHIP session on the edge SHALL log the request and drop it, as the pinned crate does.

#### Scenario: Late WHEP viewer of a WebRTC publisher
- GIVEN alice publishes `alice/cam` over WHIP in room `r1` and has sent no keyframe for 10 seconds
- WHEN bob opens a WHEP session for `alice/cam` with an `r1` token and his browser sends a PLI
- THEN alice's publisher receives a PLI
- AND bob's first decoded frame arrives within 2.5 seconds of his WHEP request

#### Scenario: Viewer in another room
- GIVEN alice publishes `alice/cam` over WHIP in room `r1`
- WHEN a WHEP session with an `r2` token plays `alice/cam` and sends PLI
- THEN alice's ingest receives no request from that session

#### Scenario: Recovery after viewer-side loss
- GIVEN bob plays alice's WHIP broadcast over WHEP through a lossy proxy
- WHEN everything toward bob is dropped for 1.5 seconds
- THEN bob's next decoded frame arrives within 1.2 seconds after the burst ends
- AND alice's `pliCount` has risen

### Requirement: Keyframe requests to one publisher are throttled
For each video line of a WHIP ingest, PLIs caused by the period, a join, loss, or a viewer's request SHALL be sent at most once per second. A request inside that second SHALL be held and sent once when the second ends. A keyframe received while a request is held SHALL cancel it. The first-keyframe and timeline-step requests of the pinned crate SHALL keep their own behaviour. No number of viewers or requests SHALL raise the rate above one requested keyframe per line per second, and a publisher answering at that rate SHALL NOT be closed by the ingest cap.

#### Scenario: PLI storm from one viewer
- GIVEN alice publishes over WHIP with a 2.5 Mbit/s cap
- WHEN a WHEP client sends a PLI every 50 milliseconds for 20 seconds
- THEN alice's `keyFramesEncoded` rises by at most 21 plus any resolution changes in that time
- AND alice's WHIP session is not ended with `RateLimited`

#### Scenario: Requests coalesce
- GIVEN a video line that sent a PLI at time t
- WHEN five requests arrive between t and t + 1 second and no keyframe arrives
- THEN exactly one PLI is sent at t + 1 second

#### Scenario: A keyframe answers a held request
- GIVEN a video line that sent a PLI at time t and holds a request made at t + 0.5 seconds
- WHEN a keyframe arrives at t + 0.7 seconds
- THEN no PLI is sent at t + 1 second

### Requirement: The keyframe patch is carried without moving the moq pin
The edge's `moq-webrtc` SHALL be the vendored copy at `native/vendor/moq-webrtc/`: upstream `rs/moq-webrtc` at `4a6f522483168ace392718d68b58a402533c897d` plus only the patch exported in its `patches/` directory, with upstream's `LICENSE-MIT` and `LICENSE-APACHE` and a `VENDOR.md` that names the base, the upstream PR tracking bead and the drop condition. Only the consuming workspace's root manifest SHALL patch `moq-webrtc` to that path. Every other moq crate SHALL resolve from `git+https://github.com/moq-dev/moq?rev=4a6f52248`, with one copy of each in the consumer's graph. `native/mjolnir_relay/Cargo.toml` and `native/mjolnir_relay/Cargo.lock` SHALL be byte-identical before and after this change.

#### Scenario: Vendored tree matches upstream plus the patch
- GIVEN `native/vendor/moq-webrtc/`
- WHEN `scripts/check-vendored-moq-webrtc.sh` reverses `patches/0001-edge-keyframes.patch` and compares `src/` to `rs/moq-webrtc/src` at `4a6f522`
- THEN the trees are identical

#### Scenario: Relay untouched
- GIVEN the commit before this change and the commit that lands it
- WHEN the two are compared under `native/mjolnir_relay/`
- THEN there is no difference, and `cargo metadata --locked` succeeds in the relay

#### Scenario: One moq-net in the consumer
- GIVEN the harness workspace with the `[patch]` line
- WHEN `cargo tree --locked -i moq-webrtc` and `cargo tree --locked -d` run there
- THEN `moq-webrtc` resolves to the vendored path, no moq crate appears twice, and cargo prints no unused-patch warning
