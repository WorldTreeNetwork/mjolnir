# Spike S4 `moq-webrtc-embed` and S7 `protected-refusal`: findings

Date: 2026-11-25/26 (UTC). moq pinned at `4a6f522483168ace392718d68b58a402533c897d` (`moq-webrtc` 0.3.12, str0m 0.25.0).
Harness: in-process `moq-relay` with the Mjolnir WebTransport decider (`mjolnir_relay::spawn_web_decider`), room
tokens shaped as `Mjolnir.Relay.Mint` signs them, default wire versions (sessions negotiated `moq-lite-06` over
WebTransport). Browsers: Playwright Chromium 158.0.8127.18 and Firefox 159.0 on macOS 27.0.1 (M1 Max).
WebRTC legs are not end-to-end encrypted (accepted by Duke on 2026-11-25).

"Content-ok" means the decoded media matches the fixture, not that a decoder exited 0. Each WebRTC publisher's
fake camera is a Y4M of two coloured halves and its fake microphone a pure tone (alice: magenta|teal, 1000 Hz;
bob: orange|blue, 600 Hz; native carol: green|purple, 440 Hz). Readers decode and compare the mean colour of each
half per frame (tolerance 45 per channel) and the FFT peak of the audio (within 3 %) (`analyze.py`, or
`window.content()` in `pages/rtc.js` for browsers).

## Verdicts

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | WHIP in: Chromium publishes with a room token; MoQ readers get decodable video and audio | **GO** for plain MoQ subscribers (VP8, H.264, VP9, AV1; early and late joiners). **INCONCLUSIVE** for a Hang watch page (not built). The moq-mux MKV exporter, a player-shaped consumer, failed on VP9/AV1 and on an uncapped VP8 late join | `logs/claim1-whip-{VP8,H264,VP9,AV1,VP8-uncapped}.log` |
| 2 | WHEP out: a MoQ publisher plays in Chromium, Firefox, Safari | **GO** Chromium (VP8, H.264, VP9, AV1) and Firefox (VP8, H.264, VP9). Firefox AV1: 201 with audio only, no video. **INCONCLUSIVE** Safari: WebDriver refused, remote automation is off | `logs/claim2-whep-{vp8,h264,vp9,av1}.log`, `logs/claim2-safari.log` |
| 3 | Round trip: two WebRTC + one MoQ participant see and hear each other | **GO**. All six directions content-ok | `logs/claim3-room.log` |
| 4 | Authorization: foreign label, foreign room, no token refused; expiry ends the session | **GO**. Expiry ends both legs at exp+1 ms (edge timer) or exp+18 ms (relay alone); browsers notice ~6–7 s later | `logs/claim4-auth.log`, `logs/claim4-expiry-relay-only.log` |
| 5 | Codecs, simulcast, loss | **GO** codecs (table below) and loss at 5 % (NACK both ways). **NO-GO** simulcast/layer choice: accepted in SDP, one layer published, no per-viewer selection. Keyframe handling is a gap (see below) | `logs/claim5-loss-simulcast.log`, source citations |
| 6 | S7: WHEP of a protected broadcast plays nothing; plaintext WHIP is not rendered by protected readers | **GO**. WHEP refused with HTTP 422 in ~35 ms, no media negotiated. The error is generic (`mux error: moq: not found`), not typed as "protected" | `logs/claim6-protected.log` |
| 7 | Cost per WebRTC participant at 720p; UDP port model | **GO (rough)**. Release edge, % of one M1 Max core: WHEP 720p 2 Mbit/s: 1 → 3.0 %, 4 → 17 %, 8 → 47 % (superlinear); WHIP: 1 → 1.6 %, 4 → 5.7 %. One shared public UDP port | `logs/claim7-cost.log` |
| 8 | Builds on Linux x86_64 with the relay toolchain, no Node; deps; size; licences | **INCONCLUSIVE** for the Linux build: every Linux host timed out on SSH. **GO** for the rest: macOS release build, no Node/npm in any build script, all licences permissive | `logs/claim8-build.log` |

## Evidence

### The edge (`rust/src/bin/edge.rs`, 270 lines, 233 without blanks and comments)

- `POST /whip/<room>/<broadcast…>` and `POST /whep/<room>/<broadcast…>`, `GET /roster/<room>`, `DELETE /session/<id>`,
  permissive CORS (preflight for `Authorization`).
- Path shape: `<broadcast>` is relative to the token's root, so it is the same name a MoQ client in the room uses
  (`alice/cam`). This keeps the grant check literal: `grant.publish.path.matches(broadcast)` for WHIP and
  `grant.subscribe.path.matches(broadcast)` for WHEP. `<room>` is only checked against the last segment of the
  verified root `t/<owner>/<room>`, never used to build a path. The owner stays out of the URL.
- Verification is `mjolnir_relay::assess(token, "", keys, DEFAULT_MAX_TTL)`, the relay's own profile (algorithm,
  signature, `iat`/`exp`/ttl, root shape), with the relay's public verify set file.
- Each accepted offer opens a relay session with the same token (`https://relay/?jwt=…`), publisher or subscriber,
  then calls `whip::accept` / `whep::accept` with that session's origin. A task drives `Response::run` and ends it
  on whichever comes first: the WebRTC session ending, the relay session closing, or the token's `exp`.
- `EDGE_INGEST_MBPS` sets `Ingest::rate`. It turned out to be required (claim 1, "BWE").

### Claim 1: WHIP in

Chromium publishes `alice/cam`; `dave` subscribes before the publish and `erin` ~7 s after, both as plain MoQ
subscribers (`harness raw`: newest video rendition → IVF or Annex-B, audio → Ogg Opus). Cap 2.5 Mbit/s.

| Codec | dave (early) | erin (late) | moq-mux MKV exporter (late) |
|---|---|---|---|
| VP8 | 422/422 frames, 1000 Hz | 212/212, 1000 Hz | 151/151, 1000 Hz |
| H.264 (OpenH264, 42001f) | 235/235, 1000 Hz | 235/235, 1000 Hz | 180/180, 1000 Hz |
| VP9 | 117/117, 1000 Hz | 61/61, 1000 Hz | nothing |
| AV1 (libaom) | 174/174, 1000 Hz | 60/60, 1000 Hz | nothing |
| VP8, uncapped | 422/422, 1000 Hz | 394/394, 1000 Hz | nothing |

What needed attention:
- **No REMB without a cap.** An uncapped ingest sends no REMB (`session.rs:424-450` sends only for a capped
  `IngestRate`), so Chromium's estimate stays near its start: 640×360, ~60 kbit/s, 1–2 keyframes in 15 s. With a cap
  the edge sends REMB at 0.9 × cap (`rate.rs:31-33`) and Chromium climbs to 960×540 or 1280×720.
- **Keyframes.** Chromium sends a keyframe only when asked or when it changes resolution. The ingest asks (PLI)
  only until a line's first keyframe and after a timeline step (`session.rs:36-38`, `296-313`). Nothing asks when a
  new MoQ subscriber arrives. A late plain subscriber still gets the in-progress group from its keyframe (erin,
  uncapped: 394 frames = ~7 s of backlog then live), so it can decode, but must chew through the backlog.
- **Renditions churn.** For H.264, VP9 and AV1 each resolution change publishes a new rendition (`0.avc3/1`,
  `0.vp9/2`, …). VP8 keeps one track. A consumer has to follow catalog updates.
- **Player-shaped consumer.** The moq-mux MKV exporter (latency window, catalog selection) produced nothing for
  VP9/AV1 and for the uncapped VP8 late join, even with a 30 s window, while a plain subscription on the same
  broadcast decoded. The cause was not isolated. A Hang watch page applies similar logic and was not built here
  (the e2ee harness's JS build needs the moq JS tree and `@moq/libav`, which is not on this Mac). Treat browser MoQ
  playback of WHIP-origin broadcasts as unproven.

### Claim 2: WHEP out

Native carol publishes ffmpeg-encoded fixture media (fMP4 for H.264, Matroska for VP8/VP9/AV1, 20 ms fragments);
the browser plays `carol/cam` for 8 s and samples decoded pixels and the audio spectrum.

| Source | Chromium 158 | Firefox 159 |
|---|---|---|
| VP8 | 264 frames, 1280×720, 0 freezes, colours match, 436 Hz | 264, 1280×720, 0, match, 436 Hz |
| H.264 | 263, 1280×720, 0, match, 441 Hz | 243, 1280×720, 0, match, 441 Hz |
| VP9 | 269, 1280×720, 0, match, 436 Hz | 249, 1280×720, 0, match, 436 Hz |
| AV1 | 253, 1280×720, 0, match, 436 Hz | answer `["opus"]`: video refused, audio plays |

(436/441 Hz: FFT bin width at 48 kHz/8192 is 5.9 Hz around the 440 Hz source.)

- The edge restricts the answer to the catalog's codecs (`whep.rs:169-171`). If the browser offers none of them for
  video, the answer rejects the video line and still returns 201: a silent audio-only session.
- Audio starved (10 packets in 8 s) when my publisher emitted one-second Matroska clusters; with 20 ms clusters it
  was fine. A bursty MoQ source is a publisher problem, not an edge one.
- The edge logs `current group evicted; skipping to next buffered group` about once a second on VP8 egress; it did
  not cost a freeze.
- Safari: `safaridriver` runs but refuses a session until "Allow remote automation" is enabled in Safari's
  Developer settings (or `safaridriver --enable` with an admin password). Not changed. By hand it would also need
  a page served over HTTPS or localhost and a fake camera, which Safari does not offer.

### Claim 3: the room

alice and bob (Chromium) each WHIP their camera, `GET /roster/r1` (`["alice/cam","bob/cam","carol/cam"]`), then
WHEP every other broadcast. carol is native MoQ: publishes VP8 and reads alice and bob.

| Direction | Result |
|---|---|
| alice ← bob, alice ← carol, bob ← alice, bob ← carol | 227–295 frames each, colours match, 598 / 436 / 1001 / 436 Hz |
| carol ← alice, carol ← bob (MoQ) | 277/277 and 260/260 frames match, 1000 Hz and 600 Hz |

How a WebRTC client learns the room: WHEP is one broadcast per request, so the client must list the room
(`/roster/<room>` here, a one-shot poll over a subscriber relay session with a 700 ms announce window) and open one
WHEP PeerConnection per other participant. N participants cost each browser 1 + (N−1) PeerConnections (3 here),
each with its own ICE, DTLS and SRTP, and cost the edge N² sessions in total; in this spike each session also opens
its own QUIC connection to the relay (`claim7-cost.log` shows one loopback UDP socket per session). Joining and
leaving need polling or a server-sent event stream; the roster endpoint is not part of `moq-webrtc`.

### Claim 4: authorization

| Case | Result |
|---|---|
| alice's token, WHIP `bob/cam` | 403 `Whip of bob/cam is outside the token grant` |
| r2 token on `/whip/r1/…` and `/whep/r1/…` | 403 `token is not for this room` |
| no token / `Bearer abc` | 401 `no token` / 401 `symmetric signature` |
| token from another key, expired token | 401 `token refused` |
| `alice/%2e%2e/bob/cam` | 400 `bad broadcast path` |
| r2 token playing `carol/cam` on `/whep/r2/` | admitted by the edge but resolves under `t/<owner>/r2`, where nothing exists |
| control: alice publishes `alice/cam` | connected |

Expiry (token ttl 25 s, WHIP and WHEP open): the edge ends both at exp+0.8 ms and exp+7 ms
(`token expired (edge timer)`). With `--no-expiry-timer` the relay closes the edge's sessions at exp+18 ms and
exp+27 ms (`Session(Expired)`), which ends the WebRTC legs. The browsers report `disconnected` 6.0–7.3 s after exp:
the edge stops sending; it sends no DTLS close_notify or RTCP BYE. A bare `alice` (no suffix) also matches
`alice/**`.

### Claim 5: codecs, simulcast, loss

Codec matrix (all content-checked):

| | H.264 | VP8 | VP9 | AV1 | Opus |
|---|---|---|---|---|---|
| WHIP Chromium → MoQ | yes | yes | yes | yes | yes |
| MoQ → WHEP Chromium | yes | yes | yes | yes | yes |
| MoQ → WHEP Firefox | yes | yes | yes | no (Firefox's offer has no AV1) | yes |

The edge never transcodes: a WebRTC viewer gets the publisher's codec or nothing. A room mixing a Firefox viewer
and an AV1 publisher has no video for that viewer. H.265 is in the crate (`codec/h265.rs`) and was not tested.

- **Simulcast**: Chromium offered rids q/h/f; the answer accepted `a=simulcast:recv q;h;f`, the catalog showed one
  rendition `0.vp8` and every recorded frame was 640×360 (the `h` layer). The browser still encoded and uploaded
  all three. On egress the edge serves "the first enabled rendition" with "no ABR on the peer" (`egress.rs:259`,
  `egress.rs:372`) and only logs the viewer's REMB (`session.rs:332-336`). There is no per-viewer layer choice.
- **Loss** (lossy UDP proxy, `lossy.py`, 5 %): egress dropped 52/1030 packets toward Chromium; it sent 23 NACKs, lost
  22 packets net, decoded 458 frames with 1 freeze, no PLI, colours and tone matched. The edge resends from a
  3000-packet video buffer (`session.rs:26-30`, `845-855`). Ingest dropped 87/1937 toward the edge; the edge NACKed
  the publisher 18 times, and the MoQ reader decoded 395/395 matching frames.
- **PLI/FIR**: from a WHEP viewer they are ignored ("rely on the next natural keyframe", `session.rs:337-341`). For a
  native MoQ source with 1–2 s GOPs that is fine. For a WHIP publisher played over WHEP, the next natural keyframe
  may be many seconds away, since nothing asks the publisher.

### Claim 6: S7, protected broadcasts

alice publishes real H.264 + Opus as a `moq-e2ee` protected broadcast at `alice/<credential path>` (each plaintext
track bridged frame by frame as the add-call-e2ee page does; dummy secret 32 × 0x11).

- WHEP of `alice/<opaque>` with a valid room token: HTTP 422 `mux error: moq: not found` in ~35 ms; no answer, no
  ICE, nothing to play. The catalog is published under an HMAC-derived physical name, so the edge's
  `catalog.json` lookup finds nothing. A plain MoQ subscriber without the credential gets the same `not found`.
- Plaintext WHIP `bob/cam` with a protected reader in the room: the reader sees `bob/cam` announced, but it does
  not qualify (`qualifying_for_label=[]`, the reader looks for `bob/<credential path>`). Forced open with the
  credential, every semantic track (`catalog.json`, `0.vp8`, `0.avc3`, `1.opus`) is `not found`, so nothing is
  rendered. Control: the same broadcast decodes for any room member without a credential (230/230 frames, 600 Hz).
- The refusal is structural, not a check: the edge cannot tell "protected" from "no catalog yet". It also admits a
  plaintext WHIP into a room whose clients are protected, because a room token does not say what kind of room it is.

### Claim 7: cost and ports

Release edge on an M1 Max (10 cores; load average 4–11 from other work during the run), `ps` once a second:

| Load | Edge CPU, % of one core (mean / max) | RSS (one process, cumulative across phases) |
|---|---|---|
| idle, or native MoQ source with no viewers | 0 % | 9 MiB |
| 1 / 4 / 8 WHEP viewers, H.264 720p ~2 Mbit/s | 3.0 / 17.0 / 47.3 % (max 53 %) | 29 / 43 / 69 MiB |
| 1 / 4 WHIP publishers, H.264, Chromium settled at 640 px ~1.8 Mbit/s | 1.6 / 5.7 % | 74 / 100 MiB |

Per WHEP session that is 3 % alone and about 6 % at eight: superlinear, cause not isolated (eight relay sessions,
eight egress pumps, and Chromium decoding eight streams on the same machine). Node G must measure on the Linux host.

Ports: every WHIP and WHEP session shares one UDP socket, demuxed by ICE ufrag ("a deployment opens exactly one
media port", `server/mod.rs:150`, `161`). `lsof` during the run: one public UDP port, plus one loopback UDP socket
per session for its QUIC connection to the relay. Public exposure: HTTPS for WHIP/WHEP signalling (through the
gateway) and that one UDP port. `Server::Config::ice_candidates` advertises a NAT or public address
(`server/mod.rs` `Config`); the spike used it to put the lossy proxy in path.

### Claim 8: build and ops

- macOS aarch64, rustc 1.96.0: `cargo build --release --bin edge` in 1 m 38 s on the relay's existing release
  target. Binary 33.3 MB, 27.4 MB stripped. Most of that is the `mjolnir-relay` lib (iroh, moq-relay) linked only
  for `assess`; a product edge should share a small auth crate instead.
- `moq-webrtc` with `default-features = false` still pulls `reqwest` (the WHIP/WHEP client is not behind a feature).
- Build scripts in the tree (35 for `moq-webrtc`, 54 for the whole binary): none mentions node, npm, bun, pnpm or
  yarn. C is compiled by `ring` and `aws-lc-sys` (the relay already builds `aws-lc-sys`), `blake3` and `io-uring`.
- Licences, x86_64-unknown-linux-gnu, 332 crates under `moq-webrtc`: all permissive (MIT, Apache-2.0, ISC, BSD,
  Zlib, Unicode-3.0, CC0, CDLA-Permissive-2.0; nine crates are `Unlicense OR MIT`). No GPL, LGPL, MPL or EPL.
  `moq-webrtc` itself is `MIT OR Apache-2.0`. Nothing conflicts with an AGPL-3.0-or-later host.
- Linux x86_64 with toolchain 1.95.0: not run. morphie and the Framework laptop (all three addresses) timed out on
  SSH from 02:01Z to 02:18Z. The dependency graph resolves for that target from the relay's lockfile.

## What this means for node D (`webrtc-edge`)

The shape works: a 230-line binary verifies the room token with the relay's code, borrows the token for its relay
session and gives the relay the final say, and MoQ and WebRTC participants share a room. Before a contract:

1. **Always cap ingest.** The cap is what makes the session send REMB. Without it Chromium sends 360p at ~60 kbit/s.
   Pick a default (2.5 Mbit/s worked) and make it per owner later (node F).
2. **Keyframe policy, upstream.** Nothing asks a WHIP publisher for a keyframe after its first. MoQ late joiners
   get a long backlog and WHEP viewers of a WebRTC publisher recover from loss slowly. Needed: periodic PLI on
   ingest (every 2–4 s) or a PLI when the broadcast gains a subscriber, and forwarding of egress PLI to the source
   when the source is a WHIP session on the same edge. The session type is private, so this is a `moq-webrtc`
   change (an `Ingest` option), not edge code.
3. **One relay connection, not one per session.** Reuse a connection per token, or hold one per room per edge
   with a scope that covers the token's grant, so N participants do not open N² QUIC connections.
4. **Typed errors.** Map "catalog not found" to a distinct status the page can explain (protected or not yet
   started), and refuse a WHEP whose answer loses video (or say so in a header) instead of a silent audio-only 201.
5. **Room kind in the token.** The edge cannot know a room is protected. The mint should mark open rooms
   (for example a claim or a root segment) and the edge should refuse rooms not marked open.
6. **Roster.** Ship it as a server-sent event stream from one subscriber session per client, not a poll.
7. **Session end.** Close DTLS (or send RTCP BYE) at `exp` so the browser learns at once, not after ~6 s.
8. **Playback check.** Run the Hang watch page against a WHIP-origin broadcast before node E; the moq-mux
   player-shaped consumer failed on VP9/AV1 here.

## Limits found

- No simulcast and no per-viewer layer or bitrate choice; a viewer on a weak link gets the publisher's single layer.
- No transcoding: a viewer without the publisher's codec gets no video (Firefox and AV1).
- Rendition churn: H.264, VP9 and AV1 publishers create a new rendition per resolution change.
- PLI from viewers is ignored; keyframes come only from the source's own schedule.
- The WebRTC legs are readable by the host, as accepted.
- Superlinear edge CPU from 4 to 8 viewers on one Mac; not yet measured on Linux.
- Not tested: Safari (blocked), H.265, packet loss above 5 %, TURN (spike S5), more than three participants
  (spike S6), a Hang watch or publish page.

## Reproduce

See `README.md` and `run-all.sh`.
