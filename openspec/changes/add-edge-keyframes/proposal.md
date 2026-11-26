# add-edge-keyframes

> **PENDING**

Node `mjolnir-rurh.12` (edge-keyframes), parent `mjolnir-rurh` (platform-calls). Rigor: change. Group: solo. Blocks `mjolnir-rurh.13` (webrtc-edge). Owner decision 2026-11-25: send the change upstream and carry the patch until it lands; do not move the moq pin for it.

## Why

A browser WHIP publisher sends a keyframe only when asked or when it changes resolution, and the pinned `moq-webrtc` asks only for the first one (`add-webrtc-edge/spikes/finding.md`, claims 1 and 5). So a WebRTC-origin broadcast has one group per resolution. A late MoQ joiner decodes from that group's keyframe and then chews through seconds of backlog (about 7 s in claim 1). A WHEP viewer's PLI or FIR is logged and dropped (`session.rs:337-341` at `4a6f522`), so a viewer of a WebRTC publisher recovers from heavy loss only when the publisher happens to send a keyframe. Upstream `main` does not fix this and has no open issue or PR for it (spike `upstream-keyframes`, refuted). The session type is crate-private, so the fix is a `moq-webrtc` change.

## What

- **Policy (design D1).** A WHIP ingest's video line asks its publisher for a keyframe (PLI) when it has had none for 2 s, when a reader's join asks moq-net for a new group (`track::Info::refresh`, ratio 4), when a frame arrives after unrecoverable loss, and when a WHEP viewer of that broadcast on the same edge, in the same room, sends PLI or FIR. All four share one gate: at most one PLI per line per second. A keyframe that arrives answers a held request.
- **Patch surface (D2).** In `moq-webrtc` only, additive: `keyframe::Keyframes` (period, refresh, on_loss, min_interval) as a new field on `whip::Request`, defaulting to today's behaviour; `whip::Response::keyframes()` returning a weak `keyframe::Requester`; `whep::Request::keyframes: Option<Requester>`.
- **Viewer path (D3).** The embedder joins a WHEP session to the WHIP session with the same verified root and broadcast. The harness edge does it here. Node `.13` carries it into the product.
- **Carrying (D4).** `rs/moq-webrtc` from `4a6f522` is vendored to `native/vendor/moq-webrtc/`: pristine first, then the patch, with both licence texts, `VENDOR.md` and the exported patch. Only the consumer's workspace adds `[patch."https://github.com/moq-dev/moq"] moq-webrtc = { path = … }`. The pin is unchanged everywhere. The relay's manifest and lockfile do not change (the relay does not depend on `moq-webrtc`).
- **Licence and provenance (D5).** The patch is offered `MIT OR Apache-2.0` like the crate. `NOTICE` names the vendored code. A bead tracks the upstream PR and the drop condition.
- **Upstream (D7).** A port to `main` using `Refresh { ratio, interval }`, `Demand::poll_refresh` and, for the viewer path, `Subscriber::refresh()`. Prepared and tested on a branch here; opening it is an ASK.
- **Acceptance (D8).** A before/after contrast on the `add-webrtc-edge` spike harness, extended with timing: WHEP join and MoQ join to first decodable frame, recovery after a burst of loss on either leg, a PLI storm bound, and the keyframe cost.
- Capability: `webrtc-edge` (ADDED ×6). Node `.13` adds the edge's own requirements to the same capability.

Design and reasons: [`design.md`](design.md). Spike: [`spikes/upstream-keyframes.md`](spikes/upstream-keyframes.md).

## Impact

- Capabilities: ADDED `webrtc-edge` ("A WHIP ingest asks for a keyframe on a period", "A WHIP ingest asks for a keyframe when a reader's join wants a new group", "A WHIP ingest asks for a keyframe after unrecoverable loss", "A WHEP viewer's keyframe request reaches a same-edge WHIP source", "Keyframe requests to one publisher are throttled", "The keyframe patch is carried without moving the moq pin").
- ADRs: none (rigor `change`). `docs/plans/webrtc-turn-sfu.md` is not amended; this node is already in its DAG.
- Code, after activation: `native/vendor/moq-webrtc/` (new: vendored crate, `VENDOR.md`, `patches/`, licences), `NOTICE` (vendored-code section), `scripts/check-vendored-moq-webrtc.sh` (new), `openspec/changes/add-edge-keyframes/harness/` (copied and extended spike harness with the `[patch]` line). `CLAUDE.md` gets one line under the relay/edge notes pointing at `VENDOR.md`.
- Not changed: `native/mjolnir_relay/` (manifest, lockfile, code), `native/Cargo.toml` and `native/Cargo.lock`, the E2EE spike crates, `scripts/build-native.sh`, `scripts/deploy.sh`, the moq pin, production.
- Deploy: none. Nothing here runs on a server. The product edge (`.13`) is the first deployable consumer.

## User journey & surfaces

No new UI because the outcome reaches surfaces that node `.13` (WHIP and WHEP on the edge) and node `.15` (the WebRTC room client) own, and the existing MoQ browser client: the viewer's `<video>` starts and recovers sooner. In this change the journey is shown through the spike harness pages.

- **Working, WebRTC viewer joins late:** bob opens a WHEP session to `alice/cam` 10 s after alice started publishing over WHIP. The edge forwards bob's first PLI to alice's ingest; alice's browser sends a keyframe; bob sees video within about 2 s.
- **Working, MoQ viewer joins late:** carol subscribes to `alice/cam` through the relay. She decodes at once from a group at most about 2 s old and is live within about 2 s, instead of replaying the session since alice's last resolution change.
- **Loss:** bob's network drops everything for 1.5 s. When it returns, his PLI reaches alice and video resumes within about a second. If alice's uplink loses a burst instead, the edge asks alice itself, and MoQ readers get a fresh group within about a second.
- **Abuse:** a viewer sends PLI every 50 ms. alice still sends at most about one requested keyframe a second, and her session is not closed by the cap.
- **Off / other sources:** a WHIP session with no edge settings (upstream defaults) behaves exactly as today. A WHEP viewer of a native MoQ publisher behaves as today: its keyframes come from that publisher's own GOP. A viewer in another room cannot reach alice's ingest.

## Out of scope

- The product edge `mjolnir-rtc`, its routes, the WHIP/WHEP pairing table in product code, its `build-native.sh` branch and deploy: `add-webrtc-edge` (`mjolnir-rurh.13`).
- Moving the moq pin, and deleting the vendored crate once upstream lands: the coordinated pin move with the E2EE work (plan risk 3); tracked on the upstream bead.
- Forwarding a viewer's PLI to a native MoQ publisher (needs `Subscriber::refresh()` on `main`): upstream PR part 2, then the pin move.
- Holding deltas back after loss until the keyframe (freeze instead of corruption): not proposed; design D6.
- Simulcast, per-viewer layer choice, transcoding: plan non-goals for this intention.
- Linux and multi-viewer scale measurements: `mjolnir-rurh.7`.
- A Hang watch page check of WHIP-origin playback (finding item 8): `.13`; task C only records the exporter.
