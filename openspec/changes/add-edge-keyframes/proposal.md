# add-edge-keyframes

> **PENDING**

Node `mjolnir-rurh.12` (edge-keyframes), parent `mjolnir-rurh` (platform-calls). Rigor: change. Group: solo. Blocks `mjolnir-rurh.13` (webrtc-edge). Owner decision 2026-11-25: send the change upstream and carry the patch until it lands; do not move the moq pin for it. Owner answers to the review's five decisions, 2026-11-25: "for contract, i agree with those - wtn fork, measure cost and include in the pr, license matches upstream".

## Why

A browser WHIP publisher sends a keyframe only when asked or when it changes resolution, and the pinned `moq-webrtc` asks only while a line has no keyframe and for a timeline step (`add-webrtc-edge/spikes/finding.md`, claims 1 and 5). So a WebRTC-origin broadcast has one group per resolution. A late MoQ joiner decodes from that group's keyframe and then works through seconds of backlog (about 7 s in claim 1). A WHEP viewer's PLI or FIR is logged and dropped (`session.rs:337-341` at `4a6f522`), so a viewer of a WebRTC publisher recovers from heavy loss only when the publisher happens to send a keyframe. Upstream `main` does not fix this and has no open issue or PR (spike `upstream-keyframes`, refuted). The session type is crate-private, so the fix is a `moq-webrtc` change.

## What

- **Policy (design D1, D2).** With the policy enabled, a WHIP video line asks its publisher for a keyframe (PLI) on a 2 s period, when a join wants a group past the newest (`track::Info::refresh` ratio 4), after unrecoverable loss, and when a paired WHEP viewer sends PLI or FIR. **Every PLI on the line, the two pinned paths included, passes one cooldown of 1 s**, with at most one held request per line. A timer never sends to a line without a receive stream and never ends a session. With the policy disabled the crate behaves as pinned. The settings are a trial, adopted only after the cost and storm measurements.
- **Residual.** One authorised viewer can hold a publisher's line at one PLI per second. The floor bounds feedback, not encoder output or admission under the ingest cap.
- **Two seconds is a request cadence.** The edge asks; an encoder may ignore it. Timings are local acceptance targets on the harness, not requirements.
- **Viewer path (D3).** Each WHIP session has its own receiver; its `Requester` is weak and returns `Retired` once the session ends, so a viewer of a replaced publisher can never reach the new one. Requests are honoured only for the session's one video line, its own tracks, and its own instance when known. The embedder pairs sessions only after token and path-grant checks, keyed by full verified root and canonical path, and removes an entry only if it still belongs to the ending session.
- **Patch surface (D4).** In `moq-webrtc` only, additive: `keyframe::Keyframes` on `whip::Request` (default off), `Response::keyframes() -> Option<Requester>` (`None` for WHEP), `whep::Request::keyframes`.
- **Carrying (D5).** Feasibility first: a scratch consumer build on macOS and Linux with package-id checks. Then `rs/moq-webrtc` from `4a6f522` is vendored to `native/vendor/moq-webrtc/` with every inherited feature setting kept, its own committed lock, and a consumer-local `[patch]`. The pin is unchanged everywhere. The relay's manifest and lockfile hashes are checked before and after.
- **Licence and provenance (D6).** Upstream's MIT notice ("Copyright (c) 2023 Luke Curley") and Apache text are kept unmodified; every modified file is marked; Mjolnir's changes are offered `MIT OR Apache-2.0`, authorised by Duke for the Foundation on 2026-11-25.
- **Upstream (D8).** The builder prepares a local port to `main` (patch series, CI log, PR draft including the measured cost) in this repository. Pushing to the `WorldTreeNetwork/moq` fork and opening the PR are reserved to Duke or a submitter he names.
- **Acceptance (D9).** A before/after contrast on the `add-webrtc-edge` spike harness, extended with per-PLI and per-frame logs, a moving fixture with a frame counter, and timing on a common clock.
- Capability: `webrtc-edge` (ADDED ×5). Node `.13` adds the edge's own requirements to the same capability.

Design and reasons: [`design.md`](design.md). Spike: [`spikes/upstream-keyframes.md`](spikes/upstream-keyframes.md). Review answered: [`reviews/2026-11-25-advise.md`](reviews/2026-11-25-advise.md).

## Impact

- Capabilities: ADDED `webrtc-edge` ("Every keyframe request on a WHIP video line passes one cooldown", "A WHIP ingest asks for keyframes on a period and after loss", "A WHIP ingest asks for a keyframe when a join wants a group past the newest", "A viewer's keyframe request reaches only the live WHIP session it is paired with", "The keyframe patch is carried without moving the moq pin").
- ADRs: none (rigor `change`).
- Code, after activation: `native/vendor/moq-webrtc/` (new: vendored crate, lock, `VENDOR.md`, `patches/`, licences), `scripts/check-vendored-moq-webrtc.sh` (new), `NOTICE` (vendored-code section), `CLAUDE.md` (one line), `openspec/changes/add-edge-keyframes/harness/` (copied and extended spike harness with the `[patch]` line and the pairing table), `openspec/changes/add-edge-keyframes/upstream/` (local port, CI log, cost write-up, PR draft).
- Not changed: `native/mjolnir_relay/` (manifest, lockfile, code), `native/Cargo.toml` and `native/Cargo.lock`, the E2EE and webrtc-edge spike crates, `scripts/build-native.sh`, `scripts/deploy.sh`, the moq pin, production, any remote repository.
- Deploy: none. The product edge (`.13`) is the first deployable consumer.

## User journey & surfaces

No new UI because the outcome reaches surfaces that node `.13` (WHIP and WHEP on the edge) and node `.15` (the WebRTC room client) own, and the existing MoQ browser client: the viewer's video starts and recovers sooner when the publisher answers. In this change the journey is shown through the harness pages. Times below are the local targets on that fixture.

- **WebRTC viewer joins late:** bob opens a WHEP session to `alice/cam` 10 s after alice started publishing. The edge forwards bob's PLI to alice's session; alice's browser sends a keyframe; bob sees video within the target.
- **MoQ viewer joins late:** carol subscribes through the relay. Alice's groups last about the period, so carol decodes at once and catches up through about one period of deltas.
- **Loss:** bob's network drops everything for 1.5 s; his PLI reaches alice and fresh frames resume. If alice's uplink loses a burst instead, the edge asks alice itself.
- **Abuse:** a viewer sends PLI every 50 ms. The edge still sends alice at most one PLI per second on that line. Alice's encoder answering at that rate costs quality; that cost is measured (task F).
- **Replaced publisher:** alice reconnects. Bob's old session's requests return `Retired` and never reach the new session.
- **Off / other sources:** a WHIP session without the policy behaves as today. A WHEP viewer of a native MoQ publisher behaves as today. A viewer in another room, even with the same broadcast path, cannot reach alice's session.

## Out of scope

- The product edge `mjolnir-rtc`, its routes, the pairing table in product code, its build branch and deploy: `add-webrtc-edge` (`mjolnir-rurh.13`).
- Moving the moq pin and deleting the vendored crate: the coordinated pin move with the E2EE work (plan risk 3); tracked on the upstream bead.
- Pushing to the `WorldTreeNetwork/moq` fork and opening the upstream PR: Duke or a submitter he names.
- Forwarding a viewer's PLI to a native MoQ publisher (needs `Subscriber::refresh()` on `main`): upstream PR part 2, then the pin move.
- Holding deltas back after loss (ASK 5: keep forwarding).
- More than one video line per WHIP session for viewer pairing; simulcast layer choice; transcoding.
- Linux and multi-viewer scale measurements: `mjolnir-rurh.7`.
- A Hang watch page check of WHIP-origin playback (finding item 8): `.13`; task C only records the exporter.
