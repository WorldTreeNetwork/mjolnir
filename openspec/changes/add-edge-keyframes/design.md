# Design — add-edge-keyframes

Node `mjolnir-rurh.12`. Owner decision 2026-11-25: send the change upstream and carry the patch until it lands; do not move the moq pin for it. Evidence: `add-webrtc-edge/spikes/finding.md` (claims 1, 2, 5, "What this means for node D" item 2), the pinned source at `4a6f522` (`rs/moq-webrtc/src/{session.rs,ingest.rs,egress.rs,server/whip.rs,server/whep.rs,rate.rs,codec/mod.rs}`, `rs/moq-net/src/model/track.rs`), and spike [`spikes/upstream-keyframes.md`](spikes/upstream-keyframes.md).

Citations are `file:line` at the pin unless marked `main`.

## Context

- Chromium sends a keyframe only when asked or when it changes resolution. In 15 s it sent 1 to 3 (`claim1-whip-H264.log`: `keyFramesEncoded` 1 → 3, `pliCount` 0).
- The ingest asks only while a video line has no keyframe yet, and for a deferred timeline step (`session.rs:36-38`, `296-313`, `IngestOrder` at `487-590`). Nothing asks on a join, on a period, or after loss. str0m reports loss on every frame (`MediaData::contiguous`, str0m 0.25 `media/event.rs:252-257`), and moq-webrtc ignores it.
- A viewer's PLI/FIR reaches egress as `Event::KeyframeRequest { mid, rid, kind }` and is logged and dropped (`session.rs:337-341`).
- moq-net already has the join signal. A track whose `Info::refresh` is `Some(r)` judges each live join: once the newest group's bytes after its keyframe exceed `r` times the keyframe, `Demand::wanted` moves past the newest group and asks the publisher for a new one (`track.rs:163-174`, `1190-1234`, `5906-5947`). A new in-process cursor joins live (`track.rs:8438-8443`). moq-stats uses this pattern (`moq-stats/src/produce.rs:526`, `617`).
- Refresh does not cross a lite-06 hop (`lite/version.rs:385-390`), and lite-06 is the default wire. The edge publishes to the relay over lite-06, and in the spike each WHEP egress reads through its own relay session.
- The ingest cap meter credits a frame for its own assembly, "a keyframe larger than the burst included" (`rate.rs:40-51`). Steering is 0.9 of the cap, leaving room "for audio and keyframe overshoot" (`rate.rs:16-21`).

## D1. Policy: both periodic and on-join, plus loss and viewer requests, under one throttle

A video line of a WHIP ingest asks its publisher for a keyframe (PLI) for any of these causes:

| Cause | When | Default in the crate | Edge setting |
|---|---|---|---|
| Period | The line has received no keyframe for `period` | off | **2 s** |
| Join | `Demand::wanted` on the line's track moves past its largest group, or goes from nobody to someone | off (needs `refresh`) | **refresh ratio 4** |
| Loss | A video frame arrives with `contiguous == false` and is not a keyframe | off | **on** |
| Viewer | A WHEP session on the same edge, playing this broadcast in the same room, received a PLI or FIR | off (needs the handle) | **on** |

Every cause goes through one per-line gate: **at most one PLI per video line per `min_interval`, 1 s.** A request inside the window is held and sent once at the window's end. A keyframe that arrives while a request is held cancels it, because that keyframe answers it. The two requests that exist today (first keyframe, timeline step) keep their own 1 s repeat and are not gated, so nothing changes for them.

Why both period and join:

- **Period is the only cause that reaches MoQ readers behind the relay.** On lite-06 the relay never forwards a join (spike). Without a period, a late MoQ joiner reads a group as long as the session (7 s of backlog in claim 1, and growing). A 2 s period bounds every group, and so every joiner's catch-up, to about 2 s. 2 s is upstream's own default GOP (`moq-video` `gop = framerate * 2`, JS `keyframeInterval` 2000 ms), and upstream's verdict in #3256 is that a 2 s GOP is enough. The period is measured from the last keyframe received, so a publisher that already sends keyframes (OBS with a 2 s keyint) gets no extra PLI.
- **Join is the precise cause, and it costs nothing when nobody joins.** It fires for in-process readers and for the first subscription the relay opens, and it will fire for every relay reader once the edge-relay wire carries refresh (lite-07 final, or moq-transport DYNAMIC_GROUPS). Ratio 4 asks only when a joiner would otherwise decode more than four keyframes' worth of deltas. With a keyframe 4 to 8 times a delta frame (assumption H2) at 30 fps, that is a join more than 0.5 to 1 s into a group. Ratio 2 would ask on most joins; 8 would almost never ask under a 2 s period.

Why 1 s for the gate:

- It bounds the worst case for any number of viewers, honest or not: the publisher never sends more than about one requested keyframe per second, which is a 1 s GOP. A single viewer flooding PLI gets the same bound as a hundred viewers.
- Loss recovery needs a keyframe within about a round trip plus an encode. With NACK already recovering 5 % random loss (claim 5), PLI is for bursts NACK cannot fill, and 1 s is inside the "about two seconds" goal.
- It is the interval the crate already uses for its own repeats (`KEYFRAME_REQUEST_INTERVAL`, `session.rs:36-38`), and the interval upstream `main` exposes per hop as `Refresh::interval`.

Cost at 720p (estimate; assumption H2, measured by task F):

- At the edge's cap of 2.5 Mbit/s the encoder is steered to 2.25 Mbit/s. At 30 fps a mean frame is about 9.4 kB, and a keyframe 4 to 8 times that, 37 to 75 kB.
- Against an unbounded GOP, a keyframe every N frames costs `(K/d − 1) / N` of the stream. A 2 s period at 30 fps (N = 60) costs 5 to 12 %, 110 to 260 kbit/s of the 2.25 Mbit/s. At 15 fps it is 10 to 23 %.
- The worst case under the gate (1 s) doubles that: 10 to 23 % at 30 fps.
- Under the cap this is not extra bandwidth. REMB holds the encoder's average, so the cost shows as lower quality on the delta frames, plus a burst of one keyframe each period. The meter credits that burst (`rate.rs:40-51`). Task F checks that a 1 s storm does not trip `RateLimited`.
- The spike fixture cannot measure this. It is a static two-colour image that encoded at about 28 kbit/s (`claim1-whip-H264.log`, `bytesSent` 41720 at t = 12 s). Task F uses a moving 720p fixture.

## D2. Where the code lives: one crate, additive API, defaults unchanged

The session type is crate-private, so the change is in `moq-webrtc` only. The surface:

```rust
// moq_webrtc::keyframe (new module, re-exported)

/// When a WHIP ingest asks its publisher for a keyframe, beyond the first.
#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct Keyframes {
    /// Ask when a video line has received no keyframe for this long. `None` (default): never.
    pub period: Option<Duration>,
    /// Set `track::Info::refresh` on each video track to this ratio and ask when a join moves
    /// `Demand::wanted` past the newest group. `None` (default): never.
    pub refresh: Option<u32>,
    /// Ask when a video frame arrives after unrecoverable loss. `false` (default): never.
    pub on_loss: bool,
    /// The floor between two requests for these causes or a `Requester`, per line. Default 1 s.
    pub min_interval: Duration,
}

/// A cloneable, weak handle that asks one WHIP ingest for a keyframe. Never blocks; a no-op
/// once the session ends. Requests coalesce under the ingest's `min_interval`.
#[derive(Clone)]
pub struct Requester { /* Weak sender into the session */ }
impl Requester { pub fn request(&self); }
```

- `whip::Request` gains `pub keyframes: Keyframes` (`Default` is all off). `Request` is `#[non_exhaustive]` (`server/whip.rs:96`), so the field is additive. `Request::new` keeps today's behaviour exactly.
- `whip::Response` gains `pub fn keyframes(&self) -> Requester`. `Response` has a private field (`server/mod.rs:31-37`), so a method is additive.
- `whep::Request` gains `pub keyframes: Option<Requester>`. `Request` is `#[non_exhaustive]` (`server/whep.rs:110`). On `Event::KeyframeRequest` (PLI or FIR, any mid or rid) the egress session calls `request()` once. Without a requester it logs as today.
- Inside: `DeferredVideo::new` (`codec/mod.rs:146-155`) adds `.with_refresh(r)` to the `track_info` it already builds, and keeps a `Demand` from the track. `MediaSink` gains a defaulted method that returns the video lines' demands, so the trait change is additive. `Session::run_loop` gains one more `select!` arm: the earliest of the period deadline, the gate's release, a demand change, or a requester message. The gate is a pure struct beside `IngestOrder`, tested the same way (`session.rs:950-991`).
- PLI always, never FIR toward the publisher: the crate's own `request_keyframe` sends PLI (`session.rs:474-485`) and Chromium answers both. The PLI names the rid of the last frame seen on the line, as today.
- Not `moq_mux::Ingest`: that struct is shared by RTMP, SRT and RTSP ingest (`moq-mux/src/ingest.rs:5-9`), and putting WebRTC-only knobs there would make the patch two crates.
- The WHEP client (`client::whep`) also runs an ingest session. It keeps all causes off. Extending it is a later upstream choice.

## D3. The viewer path at the pin is an explicit handle, and the embedder wires it

At the pin, egress cannot ask through MoQ: the reader-side `Subscriber::join` is `pub(crate)` in moq-net (`track.rs:10882-10895`), and through the relay on lite-06 it would go nowhere anyway. So the crate exposes `Requester`, and the embedder joins a WHEP session to a WHIP session.

The embedder keys its table by **(verified token root, root-relative broadcast path)**, the same two values the spike edge already checks for both legs (`grant.publish.path.matches(broadcast)` for WHIP, `grant.subscribe.path.matches(broadcast)` for WHEP). A viewer can only reach a publisher in its own room. A WHEP of a broadcast with no WHIP session on this edge gets no requester and behaves as today.

In this change the table lives in the measurement harness's edge. Node `.13` (`mjolnir-rtc`) carries it into the product.

## D4. How the patch is carried: a vendored copy of the one crate, patched in one workspace

**Layout.**

- `native/vendor/moq-webrtc/` holds `rs/moq-webrtc` from `4a6f522`: `src/` byte-identical in a first commit, then the patch commit. Beside it: `LICENSE-MIT` and `LICENSE-APACHE` copied from the moq repository root at `4a6f522` (the crate directory has none), `VENDOR.md` (base, upstream URL, patch list, upstream PR link, drop condition), and `patches/0001-edge-keyframes.patch` (the patch commit, `git format-patch`).
- Its `Cargo.toml` is upstream's with the workspace inheritance written out: each `workspace = true` dependency becomes the same crate from `git = "https://github.com/moq-dev/moq", rev = "4a6f52248"` (moq crates) or the version the moq workspace names at the pin (crates.io crates: `str0m = "0.25"`, `rind-str0m = "0.25.2"`, ...). `rust-version = "1.91"`. The `workspace-hack` dev-dependency and `[lints] workspace = true` are dropped (hakari and lint levels, not behaviour). Version stays `0.3.12`. It has its own empty `[workspace]` table, so `cargo test` runs there and does not climb into `native/Cargo.toml`.
- The consumer's workspace root, and only it, adds:

  ```toml
  [patch."https://github.com/moq-dev/moq"]
  moq-webrtc = { path = "<relative>/native/vendor/moq-webrtc" }
  ```

  In this change the consumer is the harness workspace (`openspec/changes/add-edge-keyframes/harness/rust/Cargo.toml`). Node `.13` adds the same line to `native/mjolnir_rtc/Cargo.toml`, which should be its own `[workspace]` like the relay.

**Why vendored, not a fork.** A git fork patched in for `moq-webrtc` alone brings the fork's `moq-net`, `moq-mux`, `hang` and `kio` with it, because inside the moq workspace those are path dependencies (`Cargo.toml:113-160` at the pin). That is a second copy of each type, and `moq_net::origin::Producer` from the fork would not be the one the edge holds. A fork works only if every moq crate in the graph is patched to it. The vendored manifest points at the pinned git source, so the other crates unify and only `moq-webrtc` is replaced. It also keeps the build off a second remote, and the patch reviewable in this repository. The relay already adapts upstream code in-tree with a provenance header (`native/mjolnir_relay/src/iroh_sessions.rs:1-2`, LEARNINGS 2026-11-23).

**What does not change.**

- `native/mjolnir_relay/Cargo.toml` and `Cargo.lock`. The relay is its own `[workspace]` and does not depend on `moq-webrtc` at all (no `moq-webrtc` entry in its lockfile). Task C3 proves the lockfile hash is unchanged.
- `native/Cargo.toml` and `native/Cargo.lock`: no moq crate there.
- `openspec/changes/add-call-e2ee/spikes/rust/` and `add-webrtc-edge/spikes/rust/`: their manifests and locks.
- `scripts/build-native.sh`: no new branch here. Node `.13` adds its own.
- The pin `4a6f52248` everywhere.

**Build.** No build script is added; the vendored crate has none today (claim 8: no Node or npm in any build script). It builds with the relay's toolchain (1.95.0) on Linux, which task C2 checks.

## D5. Licensing and provenance

- `moq-webrtc` is `MIT OR Apache-2.0`, Copyright Luke Curley and the moq authors. Both licence texts stay with the vendored copy. Each file the patch changes gains no new header (upstream files carry none). `VENDOR.md` states the origin, the base commit, and that Mjolnir's changes are offered under the same `MIT OR Apache-2.0`.
- The patch must be `MIT OR Apache-2.0`, not AGPL. Two reasons: it modifies an `MIT OR Apache-2.0` crate whose copy we redistribute, and it is meant upstream. The Foundation holds the rights to work done for Mjolnir (CLA.md), so licensing this one patch outbound is its decision (ASK in `tasks.md`).
- Linking an `MIT OR Apache-2.0` crate into an AGPL-3.0-or-later host is the same case as today's moq crates (plan `webrtc-turn-sfu.md`: "linkable into our AGPL binaries").
- `NOTICE` gains a short "Vendored third-party code" section naming `native/vendor/moq-webrtc` and its licence, so the AGPL and MIT-client paragraphs are not read as covering it.
- **Tracking.** A bead, child of `mjolnir-rurh`, holds the upstream PR URL once one exists, and the drop condition (D7). `VENDOR.md` links the bead and the PR.

## D6. What MoQ readers gain, and what they do not

Gain:

- Every group of a WHIP-origin video track is at most about 2 s long (the period). A late MoQ joiner decodes at once from the cached keyframe, as today, but catches up through at most about 2 s of deltas instead of the whole session.
- A player-shaped reader with a latency window (moq-mux's exporter, a Hang watch page) finds a fresh group within about 2 s. In claim 1 the exporter produced nothing on uncapped VP8, VP9 and AV1 late joins. The cause was not isolated, so task C records whether this fixes it rather than gating on it (hypothesis H3).
- After a burst of loss on the publisher's uplink, the ingest asks at once (loss cause), so MoQ readers stop decoding a broken group within about a second instead of at the next resolution change.
- In-process readers, the relay's first subscription, and (when the wire carries refresh) every relay reader get a keyframe on a late join, throttled.

Not gained:

- A MoQ reader cannot ask for a keyframe. MoQ over QUIC does not lose frames inside a group, and a reader that falls behind skips to the next group boundary, which the period bounds. There is no per-reader PLI.
- On lite-06 a join at the relay sends nothing to the edge; only the period helps those readers.
- MoQ-origin broadcasts are unchanged. A WHEP viewer of a native MoQ publisher still waits for that publisher's own next keyframe (2 s GOP by default). Forwarding to it needs `Subscriber::refresh()` on `main` (D7).
- The edge still drops nothing after loss: deltas after a gap are forwarded until the requested keyframe arrives. Holding them back would make a short freeze instead of a short corruption, and changes upstream behaviour more. Not in this change.
- Group boundaries still follow keyframes only. A resolution change still starts a new rendition for H.264, VP9 and AV1 (claim 1).

## D7. Upstream PR shape, and when the carried patch is dropped

The upstream PR targets `main`, which has moved past the pin (session loop restructured; `Refresh { ratio, interval }`; `Demand::poll_refresh`; public `Subscriber::refresh()`). It is a port, not the carried diff:

1. `feat(webrtc): a WHIP ingest asks for keyframes on refresh, on a period, and after loss`. `whip::Request::keyframes` as in D2, but the join cause waits on `Demand::poll_refresh`, and video tracks carry `Refresh { ratio, interval: Some(min_interval) }`, so the per-hop floor is moq-net's own.
2. `feat(webrtc): a WHEP egress turns a viewer's PLI/FIR into a refresh`. The egress calls `Subscriber::refresh()` on the video track it serves. That reaches a WHIP ingest in-process, any publisher that honours refresh (moq-video), and any hop whose wire carries refresh. The optional `whep::Request::keyframes: Option<Requester>` stays in the PR as the out-of-band route for an embedder whose path does not carry refresh (lite-06 through a relay, as here).
3. PR body per upstream `CONTRIBUTING.md` (Problem, Approach, Impact, Alternatives, Follow-ups; `just ci` before push). The Problem section leads with the browser publisher that has no GOP schedule (claim 1 numbers), since #3256 rejected tune-in PLI for encoders that have one.

Drop condition, recorded in `VENDOR.md` and the bead: **the moq pin moves past the merge of part 1, and either part 2's `Requester` merged, or the edge's WHEP for a same-edge source carries refresh (lite-07 final default, or in-process play).** Then delete `native/vendor/moq-webrtc`, the `[patch]` lines, and the `NOTICE` section. The pin move itself rides the coordinated move the E2EE work already plans (plan risk 3); this node does not move it.

If upstream declines part 2's `Requester`, the carried patch shrinks to that one handle until the wire carries refresh. If upstream declines part 1, the patch stays whole and the bead says so; the steer decision (carry until it lands) then needs revisiting, which is an ASK at that time, not now.

## D8. Acceptance: a before/after contrast on the spike's own harness

The harness is `add-webrtc-edge/spikes/` (in-process `moq-relay` with the Mjolnir decider, the spike edge, Playwright Chromium, `harness raw` and `harness export`, `lossy.py`, `analyze.py`), copied to `openspec/changes/add-edge-keyframes/harness/` and extended:

- the WHEP page timestamps the first decoded frame with `requestVideoFrameCallback` against the `POST` start, and samples `inbound-rtp` `pliCount`, `firCount`, `freezeCount`, `totalFreezesDuration`;
- the publisher page samples `outbound-rtp` `keyFramesEncoded`, `pliCount`, `bytesSent` every second;
- `harness raw` prints the wall time of subscribe, of the first decodable frame, and the media-time lag of that frame behind the newest frame;
- `lossy.py` gains a burst mode (drop everything for a set time, once);
- a moving 720p Y4M fixture beside the two-colour one (colour check unchanged on its two halves);
- a small str0m WHEP client that sends a PLI every 50 ms (the storm).

| # | Measure | Setup | Before (captured first) | After |
|---|---|---|---|---|
| A | WHEP join → first decoded frame of a WHIP-origin broadcast | Chromium WHIP (H.264, VP8), cap 2.5 Mbit/s; a Chromium WHEP viewer joins 10 s after publish; 10 joins each | measured | median ≤ 2.0 s, max ≤ 2.5 s |
| B | MoQ late joiner: subscribe → first decodable frame, and that frame's lag behind live | as A; `harness raw` joins at 10 s, 10 joins | measured (claim 1 erin: about 7 s of backlog) | first frame ≤ 1.0 s; lag ≤ 2.2 s |
| C | Player-shaped MoQ late join (moq-mux exporter) | VP8 uncapped, VP9, AV1 | claim 1: nothing | recorded; content-ok expected, not gated (H3) |
| D1 | Recovery after a 1.5 s blackout on the WHEP leg | lossy proxy in path, burst at t = 10 s | measured | end of burst → next decoded frame ≤ 1.2 s; publisher `pliCount` rises |
| D2 | Recovery after a 1.5 s blackout on the WHIP leg | burst toward the edge | measured | MoQ reader's next keyframe ≤ 1.2 s after the burst |
| E | Storm bound | storm client on WHEP for 20 s | — | publisher `keyFramesEncoded` rises by ≤ 21 plus resolution changes; WHIP session not `RateLimited` |
| F | Keyframe cost | moving fixture, cap 2.5; period off, 2 s, and the E storm | — | recorded: keyframe share of video bytes and mean keyframe/delta size ratio |

Thresholds come from the goal ("within about two seconds") and the gate (1 s plus a localhost round trip and encode). Runs are on the Mac, as in the spike; Linux repeats belong to the scale node (`mjolnir-rurh.7`).

## Unverified hypotheses

- **H1** `refresh-join-signal`: at the pin, a new in-process subscriber on a video track with `Info::refresh = Some(4)` whose newest group is over the ratio moves `Demand::wanted` past the largest group, and the relay's first subscription to the edge does the same. Confidence medium (read from `track.rs:1190-1234`, `8438-8443`; not run). Verification: task P4's unit test and an edge log line in task B. Synthesis: none; source reading in this design.
- **H2** `keyframe-ratio`: at 720p and 2.25 Mbit/s, a Chromium keyframe is 4 to 8 times a mean delta frame for camera-like content. Confidence low (general knowledge, not measured here). Verification: task F. If the ratio is far outside, D1's cost numbers and the ratio-4 choice are revisited before fold.
- **H3** `exporter-fix`: the claim 1 exporter failures on late joins are caused by unbounded groups. Confidence low (cause not isolated in the spike). Verification: task C. If not fixed, a bead for the edge's playback check (finding item 8), not a blocker here.
- **H4** `vendored-unify`: a `[patch]` path crate whose manifest names `moq-net` and the other moq crates from `git = moq-dev/moq, rev = 4a6f52248` unifies with the consumer's own moq crates, giving one `moq-net` in the graph. Confidence high (Cargo patch semantics) but not run. Verification: task C4 (`cargo tree -d` shows no second `moq-net`).
