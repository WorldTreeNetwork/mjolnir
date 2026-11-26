# add-webrtc-edge

> **PENDING**

Node `mjolnir-rurh.13` (webrtc-edge). Rigor: architecture. Depends on accepted open-room admission (`mjolnir-rurh.11`, contract `82078ec7`, implementation `0d1b3f0a`, join-guard accept `9c83d1ad`) and on `mjolnir-rurh.12` only for the ingest keyframe cadence. Duke authorized this contract and the later build on 2026-11-26 ("ok. can you do all those?"). Product code waits for an independent accept of this file. Production enable stays a separate approval. No deploy in this change.

## Why

Open rooms need a WHIP and WHEP door onto the relay that already admits MoQ participants. The spike at `openspec/changes/add-webrtc-edge/spikes/` proved media both ways on macOS with the pinned `moq-webrtc`, but its gate checks the last room segment and a path grant. It does not require an open root, refuse a wide `t/<owner>` grant, or bind an invitation's expected full root. `Mjolnir.Relay.RoomJoin` is an Elixir comparison helper. It is not this gateway and not a browser.

## What

- **Unit.** `mjolnir-rtc`, off unless a deploy flag installs it. One public UDP media port, reserved beside the other published-port numbers. Default ingest cap 2.5 Mbit/s. Direct UDP only. No TURN username.
- **Admission before relay I/O or SDP.** One `assess` on the current relay key snapshot, using that leg's bearer. Then: root classifies as open (`t/<owner>/~open/<room>` only); the URL room segment equals that root's room segment; the client-supplied expected root equals the assessed root with no normalization; the operation matches the grant (`publish` for WHIP, `subscribe` for WHEP) on the root-relative broadcast; a wide `t/<owner>` root is refused even when the URL contains `~open`. Protected and invalid roots are `403 room_not_open`, distinct from `403 bad_token`.
- **Relay-authorized media.** Each accepted offer opens a relay session with that same token, then `whip::accept` or `whep::accept` on that session's origin. No in-process WHEP origin (`.12` withdrawal, 2026-11-26).
- **Lifetime.** Refuse an answer when `exp` has passed. Close DTLS when `exp` is reached or the relay session closes. Replacement and renewal are a new POST. The previous session stays until the new admission succeeds, then the caller deletes it. A failed renewal does not tear down a still-valid session.
- **Codec.** If the offer has video and the answer would accept none of the catalog's video codecs, respond `409 codec_unavailable` and start no session. If the broadcast has no catalog yet, `409 not_started`. Do not return a silent audio-only `201`.
- **Spike already in this directory.** Claims 1–4 and 7 are GO on macOS (Chromium, Firefox). Safari and the Linux build are owed checks, not new hypotheses. Hang-watch playback of WHIP remains unproven and is not this node's acceptance.

Capability: `webrtc-edge` (ADDED). Design: [`design.md`](design.md).

## Impact

- Capabilities: ADDED `webrtc-edge`.
- ADRs: one short ADR when the build is accepted, recording the public unit and that WebRTC legs are host-readable. Not written in this contract commit.
- Code, after accept: a new host binary and unit file under the relay deploy flag, tests for the admission order, no Elixir router change.
- Not in this change: the browser page (`.15`), roster SSE (`.14`), TURN (`.16`), production firewall, relay pin move, keyframe vendor patch (`.12`).

## User journey & surfaces

A person publishes a camera with WHIP and a room token for an open room. A second person, or a MoQ subscriber in that room, sees and hears them. A token for a protected room, a wide root, or a different expected root is refused before any SDP answer. The browser page that explains "this room is open" is `.15`.

- **Working:** open-root bearer, expected root equal to the assessed root, grant matches the broadcast, catalog has a common video codec. `201` and media through the relay.
- **Refused:** protected root, omitted kind on an old mint (root has no `~open`), wide root, mismatched expected root, foreign broadcast, missing bearer, expired token.
- **Not started:** WHEP before the publisher's catalog exists. `409`, no PeerConnection left up by the client (client rule is `.15`).
- **Off:** the unit is not installed. Nothing listens.

## Out of scope

- Roster UI and SSE (`.14`).
- Shipped page, `getUserMedia`, and the host-readable notice (`.15`).
- TURN usernames and `c2` (`.16`). Encrypted open.
- Viewer PLI forwarding and in-process playback (withdrawn on `.12`).
- Production deploy, firewall, and hostname cutover.
- Pretending `Mjolnir.Relay.RoomJoin` is this service.
