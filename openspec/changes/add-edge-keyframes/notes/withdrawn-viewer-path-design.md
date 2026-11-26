# Design — add-edge-keyframes

Node `mjolnir-rurh.12`. Owner decision 2026-11-25: send the change upstream and carry the patch until it lands; do not move the moq pin for it. Owner answers to the five review decisions, 2026-11-25: "for contract, i agree with those - wtn fork, measure cost and include in the pr, license matches upstream" (recorded on `mjolnir-rurh.12`; `tasks.md` ASK section).

Evidence: `add-webrtc-edge/spikes/finding.md` (claims 1, 2, 5, "What this means for node D" item 2), the pinned source at `4a6f522` (`rs/moq-webrtc/src/{session.rs,ingest.rs,egress.rs,server/whip.rs,server/whep.rs,server/mod.rs,rate.rs,codec/mod.rs}`, `rs/moq-net/src/model/track.rs`, `rs/moq-net/src/lite/{version.rs,track.rs}`), str0m 0.25.0 (`src/media/writer.rs`, `src/media/event.rs`), spike [`spikes/upstream-keyframes.md`](spikes/upstream-keyframes.md), and the advise [`reviews/2026-11-25-advise.md`](reviews/2026-11-25-advise.md) (send-back) with its blind take.

Citations are `file:line` at the pin unless marked `main`.

## Context

- Chromium sends a keyframe only when asked or when it changes resolution: 1 to 3 in 15 s (`claim1-whip-H264.log`, `keyFramesEncoded` 1 → 3, `pliCount` 0).
- The pinned ingest sends PLI from two places, each a real `Writer::request_keyframe` call: while a video line has had no keyframe (`Admit::Request`, `session.rs:298-305`) and for a deferred timeline step (`session.rs:308-313`). Each has its own 1 s repeat (`KEYFRAME_REQUEST_INTERVAL`, `session.rs:36-38`; `IngestOrder`, `487-590`). Nothing asks on a period, a join, or after loss. A failed request returns `Err` through `?` (`session.rs:474-485`), which ends the session.
- `Writer::request_keyframe` fails with `NotReceivingDirection` when the line cannot request, and with `NoReceiverSource(rid)` when no receive stream exists yet for that mid and rid (str0m `writer.rs:302-321`). A request from a timer can come before the first RTP packet.
- str0m marks every frame `contiguous` or not (`media/event.rs:252-257`). moq-webrtc ignores it.
- A viewer's PLI/FIR reaches egress as `Event::KeyframeRequest { mid, rid, kind }` and is logged (`session.rs:337-341`). Its mid belongs to the viewer's session. Egress serves each video line from one catalog rendition, the first enabled one in a negotiated codec (`egress.rs:257-273`), held as a `Target { path, instance, track }` (`egress.rs:339-345`).
- moq-net judges each live join of a track whose `Info::refresh` is `Some(r)`: once the newest group's bytes after its keyframe exceed `r` times the keyframe, `Demand::wanted` moves past the newest group (`track.rs:163-174`, `1190-1234`, `5906-5947`). A new in-process cursor joins live (`track.rs:8438-8443`). There is no separate rule for a first reader: the first join is judged like any other.
- Refresh is not on the lite-06 wire (`lite/version.rs:382-390`; `lite/track.rs:183`, `225`), and the spike negotiated lite-06 (`finding.md:5`).
- The ingest cap meter credits a frame for its own assembly, "a keyframe larger than the burst included" (`rate.rs:40-51`), and steers to 0.9 of the cap (`rate.rs:16-21`). That is room for overshoot, not a promise that any encoder survives the meter.
- `whip::Response` and `whep::Response` are the same type, re-exported (`server/whip.rs:20`, `server/whep.rs:21`, defined `server/mod.rs:31-37`).

## D1. Policy: four causes, one cooldown for every PLI on a line

With the policy enabled, a negotiated WHIP video line sends its publisher a PLI for these causes:

| Cause | Trigger | Trial edge setting |
|---|---|---|
| Startup (pinned) | a video frame arrives on a line that has had no keyframe | as pinned |
| Step (pinned) | a timeline step waits for a keyframe | as pinned |
| Period | the line has gone `period` since its last keyframe, or since its last PLI if that is later | 2 s |
| Join | the track's `Demand::wanted` moves past the largest group written | refresh ratio 4 |
| Loss | a non-keyframe video frame arrives with `contiguous == false`; the cause only requests, and the pinned admission decision (`IngestOrder`, `session.rs:296-305`) still decides whether that frame is forwarded | on |
| Viewer | a paired WHEP session forwards a viewer's PLI or FIR (D3) | on |

The settings are **provisional**. They are trial values until tasks F and E have run on moving input; the owner approved trying them and adopting them after measurement (ASK 4).

**One cooldown per line.** Every actual PLI on a line, startup and step included, goes through one gate per negotiated video line:

- `last_sent`: a monotonic time, advanced **only when the writer accepted the PLI**: `rtc.writer(mid)` returned a writer and its `request_keyframe` returned `Ok`. The pinned helper returns `Ok` when there is no writer at all (`session.rs:479-484`); the gate uses its own send helper that reports `Sent`, `NoWriter` or the str0m error, and only `Sent` moves `last_sent`.
- `pending`: one bit plus a bitmask of causes, and one `deadline`. At most one held request per line, whatever the number of causes or viewers.
- A cause at time `now` sends at once if `now ≥ last_sent + floor`. Otherwise it sets `pending` and `deadline = last_sent + floor`. A second cause while pending only adds its tag.
- A keyframe received on the line, the line's first keyframe included, clears `pending` and re-anchors the period.
- **Unanswered request.** If no keyframe follows a PLI, the next period request is due at `max(last keyframe, last_sent) + period`. The period deadline is computed from that, never left in the past, so the timer cannot spin. Startup keeps asking at the floor while the line has no keyframe, as pinned (pinned interval and floor are both 1 s).
- **No receiver yet, or the writer refused.** The gate sends only to a line that negotiated PLI and has a current receive stream for the rid of the last frame seen. Before the first frame, or on `NoWriter`, `NoReceiverSource` or `NotReceivingDirection`, the request stays pending, `last_sent` does not move, and the event is logged and counted. The expired deadline is then **disarmed**: the line's timer is not re-armed at a time in the past. It is re-armed only by a receive-stream transition on that line (its first frame, or a frame on a new rid), which retries at once if the floor allows, or by a strictly future deadline from another cause (period, viewer). A first keyframe cancels the held request; a first eligible delta, which proves a receive stream, may release it. A keyframe request never ends a session. The pinned `?` in `request_keyframe` stays only on the pinned paths with the policy disabled.
- **Durations are validated.** `floor` defaults to 1 s explicitly, not to a derived zero. `whip::accept` refuses an enabled policy whose `floor` or `period` is zero (`Error::InvalidKeyframes`), so no configuration can spin a timer.
- **Policy disabled** (the crate default): the two pinned paths behave exactly as at the pin, with their own repeats and their own error handling. No gate, no timer, no demand watch.

**Bounded before enqueue.** Requests from outside the session (D3) arrive through a per-session flag plus a wakeup, not a growing queue. Setting the flag twice is the same as once. The session drains it into the line's gate. Memory per session is constant in the number of viewers and requests.

**Floor: 1 s.**

- It bounds the feedback a publisher receives from all causes and all viewers: about one PLI per line per second.
- 1 s is the interval the crate already uses for its own repeats, and upstream `main`'s per-hop `Refresh::interval` is the same kind of floor.
- Loss recovery needs a keyframe in about a round trip plus an encode. NACK already recovers 5 % random loss (claim 5). PLI is for bursts NACK cannot fill.

**Residual, stated plainly.** One authorised WHEP viewer can hold a publisher's played line at one PLI per second for as long as it plays. Many viewers share that one budget. Each line and each publisher has its own. A compliant encoder answering at that rate spends more bytes on keyframes, lowers delta quality under the cap, and may overshoot the cap. The floor bounds feedback. It does not bound encoder output, and it does not promise admission under the meter (`rate.rs:18-50`), which stays unchanged. The owner accepted this as a trial (ASK 4); task F and E measure it.

**What "two seconds" means.** The period is a request cadence. An encoder may ignore a PLI, delay it, or answer with a frame the importer does not treat as a keyframe. The edge cannot force a 2 s GOP; it can only ask every 2 s. Every "within about two seconds" in this change is a local acceptance target on the tested fixture (D8), not a promise.

**Why both period and join.** The period is the only cause that reaches MoQ readers behind the relay on lite-06. It bounds a group's length to about the period when the encoder answers. Join is the precise cause for readers whose join reaches the edge, and it costs nothing when nobody joins. Ratio 4 asks when a joiner would otherwise decode more than four keyframes' worth of deltas.

## D2. Join trigger and first-reader precedence

- **Trigger.** The join cause fires when the line's track's `Demand::wanted` becomes `Some(n)` with `n` greater than the largest group written. Nothing else in demand fires it: not a reader count going from zero to one, not a `wanted` at or below the largest group.
- **Empty track.** A track with no group yet asks for group 0 (`track.rs:5906-5913`). That is not a join request: the startup cause already covers a line with no keyframe. The demand observer's first reading at session start is taken as the baseline and never fires.
- **First reader.** A first reader is judged by the ratio like any later one (`track.rs:1190-1214`). There is no first-reader exception. Under the ratio, a first join causes no PLI.
- **The relay.** At the edge, the relay is one reader. Its first upstream subscription opens a cursor in the edge's process, which moq-net judges by the ratio. Later joins at the relay, while that subscription stays open, are judged at the relay's copy. On lite-06 that copy has no refresh ratio (it is not on the wire), so those joins send nothing to the edge. If the last relay reader leaves and the relay drops its upstream subscription, the next reader opens a new one, which is judged again at the edge. Task B traces the first relay subscription and a later relay-side join separately over a real hop, and records the negotiated wire version; task P4 covers the in-process cases deterministically.
- Neither case escapes the line's gate.

## D3. The viewer path: feedback only from media proven to come from the paired WHIP session

At the pin, egress cannot ask through MoQ: `Subscriber::join` is `pub(crate)` (`track.rs:10882-10895`), and on lite-06 through the relay it would go nowhere. So the crate exposes a requester and the embedder pairs sessions. A requester handle alone proves which WHIP session receives a call. It does not prove which session supplied the media the viewer is playing: `whep::accept` resolves its source separately (`server/whep.rs:163`, `resolve` at `226-239`, `follow(path, None)`), and two WHIP generations can be live at once under the same root, path and track name (the pinned replacement test keeps the old session open, `server/whip.rs:345-362`). So feedback is bound to the served media, and fails closed when that binding cannot be proven.

**What binding exists at `4a6f522`.**

- `moq_net::Instance` "names one continuous stream at a path" (`instance.rs:5-17`). A WHIP route's instance is created with the route (`origin.rs:3229-3238`, read by `whip::accept` as `route.instance()`).
- `origin::Consumer::follow(path, instance)` and `request(path, instance)` take an instance and pin the stream to it (`origin.rs:8076-8084`, `8142-8151`; `RouteInfo::instance`, `origin.rs:594`: "Pass it to `Consumer::request` to pin this stream").
- **The instance is carried only in process.** Announcements carry their instance only from lite-07 (`lite/version.rs:348-356`); on lite-06 and earlier "the receiving session mints an instance for each announcement" (`Instance::minted`, `instance.rs:35-41`). So a WHEP that reads through the relay on the default wire sees a minted instance that cannot be tied to any WHIP generation. A catalog's optional rendition instance (`Target::instance`, `egress.rs:293-304`) is set by the publisher of the catalog, and the WHIP ingest's catalog does not set it.
- **Therefore the only trusted binding at the pin is in-process:** the edge resolves the WHEP source from the WHIP session's own origin, pinned to that session's route instance. Every other path gets no feedback. This change does not promise a binding through the relay; that needs lite-07 instance carriage or `Subscriber::refresh()` on `main` (D8).

**Crate side.**

- Each accepted WHIP session creates its own fresh receiver (the flag and wakeup of D1) and a `Requester` holding only a weak reference to it. The receiver lives in the session's run loop and is dropped when the run ends: peer DELETE, disconnect, ICE timeout, error, token expiry, or cancellation by the embedder. That happens regardless of the broadcast's linger (`Session::finish`, `session.rs:184`), so a lingering broadcast takes no feedback.
- `Response::keyframes() -> Option<Requester>`: `Some` for a WHIP response, `None` for a WHEP response (the type is shared). `Requester::instance()` returns the WHIP route instance.
- `whep::Request` gains `pub source: Option<moq_net::Instance>`. When `Some`, `resolve` calls `follow(path, Some(instance))` instead of `follow(path, None)`, so the egress source is that stream or nothing. It also gains `pub keyframes: Option<Requester>`.
- **Egress eligibility.** On `Event::KeyframeRequest` (PLI or FIR) on its video line, egress forwards only when all hold: the request carried both a `source` instance and a requester, and the requester's instance equals it; the line is serving a video rendition whose `Target.path` resolves to the requested broadcast itself (no cross-broadcast reference, `egress.rs:307-323`); and the rendition's catalog instance is absent or equal to the pinned instance. The check is repeated whenever the egress moves to another rendition. Anything else is `Ignored(Unbound)` at the egress, counted, and nothing reaches any publisher. Audio-line requests and requests before a rendition is served are dropped and counted.
- `Requester::request(track: &str, instance: &moq_net::Instance) -> Requested`, where `Requested` is `Sent`, `Coalesced`, `Retired` (the session ended), or `Ignored(reason)` (`Disabled` when the policy is off, `Ambiguous`, `WrongTrack`, `WrongInstance`). The WHIP session checks again on receipt: the instance must be its own route instance, the track one of its own video tracks (any rendition its line created, since H.264, VP9 and AV1 make one per resolution), and it must have exactly one negotiated video line with PLI. It never blocks and never fails the caller.
- **One unambiguous video line.** With zero or several negotiated video lines, the request is `Ignored(Ambiguous)`. This is the supported pairing: one camera per WHIP session, as in the spike and the plan. Simulcast layers on that line are one line; the PLI goes to the rid of the last frame seen.

**Embedder side (harness edge here, `mjolnir-rtc` in node `.13`).**

- Verify the token and match the operation's path grant first, as the spike edge does for both legs (`edge.rs:58`, `98`). Pairing never happens for a request that failed either check.
- Key the table by (full verified root, canonical root-relative broadcast path). Each entry holds, read and written under one lock: the generation id (the WHIP resource id), that session's `Requester`, its route instance, and an in-process consumer of the origin the WHIP session publishes into (the spike edge spawns one origin per WHIP session, `edge.rs:110-128`).
- On WHIP accept, insert or replace the entry. On WHIP end, remove it only if its generation is still the finishing session's, so a late cleanup cannot remove a replacement.
- **On WHEP accept with an entry:** take generation, requester, instance and consumer in one read, then call `whep::accept` with that consumer, `source: Some(instance)` and the requester. The viewer is then playing exactly that generation or nothing. This removes the race between lookup and resolution: if S2 replaces S1 after the read, the viewer still resolves S1 by its pinned instance and S1 receives its feedback, which is correct because S1 is what it plays.
- **If pinned resolution fails** (S1 ended between the read and the resolve, or the catalog did not appear), the edge plays the broadcast through the relay with `source: None` and no requester. The viewer gets media and the periodic cadence, and no feedback. This is the fail-closed path, and it is counted.
- **Without an entry**, the WHEP plays through the relay as in the spike, with no requester.
- **Replacement versus retirement.** Replacing S1 with S2 does not retire S1's feedback: viewers already bound to S1 still play S1 and still reach it, until S1's session ends, after which their calls return `Retired`. New viewers bind to S2.
- **Consequence for `.13`.** A WHEP of a same-edge WHIP source plays from the edge's own process, not through the relay. The edge has already checked the token and the subscribe grant, the same checks the relay applies, and its expiry timer ends the play at `exp`. But the relay does not see that leg, so per-owner metering (`mjolnir-rurh.4`) must count edge-local plays at the edge. This is recorded in the handoff to `.13`.

Tests (P6, P6b, D3a–D3e in `tasks.md`):

- replacement **during** WHEP source resolution, with S1 and S2 both live, identical track names and no catalog instance: the viewer's requests reach only the generation whose media it plays, the other publisher's counter does not move, and a forced resolution failure takes the fail-closed path with neither publisher receiving anything;
- a sibling catalog reference with the same track name: `Ignored(Unbound)` and no PLI anywhere;
- a positive forwarding case with the WHIP publisher on the default wire to the relay (lite-06), so the binding does not silently disable the feature;
- two active rooms with the same broadcast path, positive and negative in the same run;
- a viewer bound to S1 while S2 replaced it: still reaches S1 while S1 lives (replacement), `Retired` once S1 ends (retirement), and never reaches S2;
- a late cleanup from S1 leaves S2's entry in place.

## D4. Patch surface: one crate, additive, defaults unchanged

```rust
// moq_webrtc::keyframe (new module, re-exported)

#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct Keyframes {
    /// `false` (default): the pinned behaviour, no gate, no new causes.
    pub enabled: bool,
    /// Period cause. `None` (default): off. `Some(ZERO)` is refused when enabled.
    pub period: Option<Duration>,
    /// Join cause: `track::Info::refresh` on video tracks. `None` (default): off.
    pub refresh: Option<u32>,
    /// Loss cause. `false` (default): off.
    pub on_loss: bool,
    /// The one cooldown per line for every PLI while enabled. Zero is refused when enabled.
    pub floor: Duration,
}

impl Default for Keyframes {
    // Written by hand: a derived Default would make `floor` zero.
    fn default() -> Self {
        Self { enabled: false, period: None, refresh: None, on_loss: false, floor: Duration::from_secs(1) }
    }
}

#[derive(Clone)]
pub struct Requester { /* Weak reference to one WHIP session's receiver, plus its route instance */ }
pub enum Requested { Sent, Coalesced, Retired, Ignored(Ignored) }
pub enum Ignored { Disabled, Ambiguous, WrongTrack, WrongInstance, Unbound }
```

- `whip::Request` gains `pub keyframes: Keyframes`. `Request` is `#[non_exhaustive]` (`server/whip.rs:96`), so the field is additive, and `Request::new` keeps today's behaviour. `whip::accept` returns `Error::InvalidKeyframes` for an enabled policy with a zero `floor` or `period`.
- `Response` gains `pub fn keyframes(&self) -> Option<Requester>` (additive; `Response` has a private field).
- `whep::Request` gains `pub source: Option<moq_net::Instance>` (pins `resolve`'s `follow`) and `pub keyframes: Option<Requester>` (`#[non_exhaustive]`, `server/whep.rs:110`). Both default to `None`, which is the pinned behaviour.
- Inside: `DeferredVideo::new` (`codec/mod.rs:146-155`) adds `.with_refresh(r)` to the `track_info` it builds and keeps the track's `Demand`. `MediaSink` gains a defaulted method returning the video lines' demands and track names (additive). `Session::run_loop` gains one `select!` arm: the earliest armed deadline (period or gate; a disarmed line contributes none), a demand change, or the requester wakeup. The gate is a pure struct beside `IngestOrder`, tested the same way (`session.rs:950-991`). Both pinned call sites route through the gate when enabled. The egress keeps its pinned instance and re-checks eligibility on each rendition change.
- PLI only toward the publisher, as the pinned `request_keyframe` sends (`session.rs:474-485`).
- Not on `moq_mux::Ingest`: that struct is shared by RTMP, SRT and RTSP (`moq-mux/src/ingest.rs:5-9`), and WebRTC-only knobs there would make the patch two crates.
- The WHEP client (`client::whep`) also runs an ingest session. It keeps the policy disabled.

## D5. Carrying: a vendored copy of the one crate, patched in one workspace (owner: ASK 3)

**Feasibility first.** Before any harness or patch work, task K1 has two separate subjects, each on macOS and on Linux: (a) it builds a scratch copy of the spike **consumer** with the `[patch]` line pointing at the pristine vendored crate, its `mjolnir-relay` path dependency rewritten to this checkout's `native/mjolnir_relay`, and checks package ids; (b) it runs the **vendored crate's own tests** in the vendored crate's workspace. The review's scratch resolution found the consumer selects local `moq-webrtc 0.3.12` and one `moq-net 0.3.10` from the exact git source and rev, but nothing was compiled and no other platform was tried.

**Layout.**

- `native/vendor/moq-webrtc/` holds the whole `rs/moq-webrtc` directory from `4a6f522` (`src/`, `CHANGELOG.md`, `MIGRATE.md`, `clippy.toml`): first byte-identical except the manifest, then the patch commit.
- `LICENSE-MIT` and `LICENSE-APACHE` are copied byte-for-byte from the moq repository root at `4a6f522`; the crate directory has none. The MIT notice stays exactly "Copyright (c) 2023 Luke Curley".
- `VENDOR.md`: base commit and URL; a table of every packaging difference (manifest lines rewritten, dev-dependency removed, lints dropped, `[workspace]` added, licence files added); the patch list; who authorised the outbound licence and when (D6); the tracking bead; the drop condition (D8).
- `patches/0001-edge-keyframes.patch`: the patch commit, `git format-patch`.
- Its own `Cargo.lock` and an empty `[workspace]` table, so `cargo test` runs there and does not climb into `native/Cargo.toml`.

**The rewritten manifest keeps every inherited setting, not just versions.** Each `workspace = true` dependency becomes the moq workspace's entry at the pin, with its `default-features` and `features` merged with the crate's own:

| Dependency | Source at the pin | Settings to keep |
|---|---|---|
| `axum` | crates.io `0.8` | optional; `default-features = false`; features `form, http1, json, matched-path, original-uri, query, tokio, tracing` |
| `str0m` | crates.io `0.25` | `default-features = false` |
| `reqwest` | crates.io `0.13` | `default-features = false`; features `rustls-no-provider` |
| `moq-crypto` | git `4a6f52248` | `default-features = false`; features `provider` |
| `moq-tokio` | git `4a6f52248` | `default-features = false` (dependency and dev-dependency) |
| `kio` | git `4a6f52248` | features `runtime` |
| `moq-mux` | git `4a6f52248` | features `async` |
| `tokio` | crates.io `1.48` | features `full`; dev: `test-util` |
| `hang`, `moq-net` | git `4a6f52248` | defaults |
| `rind-str0m`, `bytes`, `thiserror`, `tracing`, `url`, `uuid`, dev `rind`, dev `tracing-test` | crates.io, versions as the moq workspace names them | as upstream |

The crate's `[features]` table (`default = ["server"]`, `server = ["dep:axum"]`) is unchanged. `workspace-hack` (dev, a path into the moq tree) is removed; `[lints] workspace = true` is removed; `rust-version = "1.91"`. Version stays `0.3.12`. Task K2 checks the manifest against this table mechanically.

**Locks before `--locked`.** The vendored crate's lock and the harness consumer's lock are each written once by an unlocked resolution, reviewed (every moq package from `git+https://github.com/moq-dev/moq?rev=4a6f52248#4a6f522483168ace392718d68b58a402533c897d`, `str0m 0.25.0`), and committed. Every later build and test runs `--locked`.

**The consumer's root manifest, and only it,** adds:

```toml
[patch."https://github.com/moq-dev/moq"]
moq-webrtc = { path = "<relative>/native/vendor/moq-webrtc" }
```

Here the consumer is the harness workspace (`openspec/changes/add-edge-keyframes/harness/rust/`). Node `.13` adds the same line to `native/mjolnir_rtc/Cargo.toml`, its own `[workspace]` like the relay.

**Why vendored, not a fork.** Inside the moq workspace, `moq-net`, `moq-mux`, `hang` and `kio` are path dependencies (`Cargo.toml:113-160`). A fork patched in for `moq-webrtc` alone would bring the fork's copies with it, and their types would not be the edge's. The vendored manifest names the pinned git source, so the other crates unify and only `moq-webrtc` is replaced.

**What does not change.** `native/mjolnir_relay/Cargo.toml` and `Cargo.lock` (the relay is its own workspace and has no `moq-webrtc` in its graph); `native/Cargo.toml` and `native/Cargo.lock`; the E2EE and webrtc-edge spike crates; `scripts/build-native.sh`; the pin. Cargo does not forbid unrelated edits to those files, so byte equality is a delivery check (tasks K0, K5), and a concurrent unrelated edit by another agent is told apart from this change by `git log` on those paths.

**Builds on this Mac.** Check `df -h /System/Volumes/Data` first, use a scratch `CARGO_TARGET_DIR` outside the repository, and delete it afterwards.

## D6. Licensing and provenance (owner: ASK 2)

- `moq-webrtc` is `MIT OR Apache-2.0`. Both licence texts stay with the copy, unmodified. The MIT notice stays "Copyright (c) 2023 Luke Curley".
- **Modified files are marked**, for redistribution under the Apache option (section 4(b)). Each source file the patch changes, and the rewritten `Cargo.toml`, carries a prominent comment at the top: modified by the Mjolnir contributors for World Tree Network Foundation in 2026, what was changed, and the upstream path and commit. The headers are part of the patch, so reversing the patch restores upstream byte for byte. `VENDOR.md` alone is not enough.
- **Outbound licence.** Mjolnir's changes are offered under `MIT OR Apache-2.0`, matching upstream. Authorised by Duke Jones for World Tree Network Foundation on 2026-11-25 ("license matches upstream", recorded on `mjolnir-rurh.12`). `VENDOR.md` records that line. CLA.md has contributors keep copyright and grant rights to the Foundation; this is the Foundation's decision about its changes.
- Linking an `MIT OR Apache-2.0` crate into an AGPL-3.0-or-later host is the same case as today's moq crates.
- `NOTICE` gains a "Vendored third-party code" section naming `native/vendor/moq-webrtc`, its licence and copyright holder.
- Task K2's check verifies the licence files against the upstream root, the manifest against D5's table, and every modified file's header.

## D7. What MoQ readers gain, and what they do not

Gain, when the publisher answers PLIs:

- Groups of a WHIP-origin video track last about the period. A late MoQ joiner decodes from the cached keyframe at once, as today, and catches up through about one period of deltas instead of the whole session.
- A player-shaped reader with a latency window finds a fresh group within about the period. Whether this fixes claim 1's exporter failures is recorded, not gated (H3).
- After loss on the publisher's uplink, the loss cause asks at once, subject to the floor.
- Readers whose join reaches the edge (in-process, and the relay's first upstream subscription) get a keyframe on a late join, subject to the ratio and the floor.

Not gained:

- No per-reader keyframe request for MoQ readers. A reader that falls behind skips to the next group boundary.
- Later joins at the relay on lite-06 send nothing to the edge (D2).
- MoQ-origin broadcasts are unchanged. A WHEP viewer of a native MoQ publisher still waits for that publisher's next keyframe.
- Deltas after loss are still forwarded until the keyframe arrives, which can show corruption briefly (ASK 5: keep forwarding).
- A publisher that ignores PLI gets no shorter groups. The edge asks; it cannot compel.

## D8. Upstream PR, and when the carry is dropped (owner: ASK 1)

The upstream PR targets `main`, which has moved past the pin. It is a port, not the carried diff:

1. `feat(webrtc): a WHIP ingest asks for keyframes on refresh, on a period, and after loss`, with one cooldown per line covering every PLI. On `main` the join cause waits on `Demand::poll_refresh`, and video tracks carry `Refresh { ratio, interval: Some(floor) }`.
2. `feat(webrtc): a WHEP egress turns a viewer's PLI/FIR into a refresh`. Egress calls `Subscriber::refresh()` on the track it serves. The optional `Requester` stays in the PR as the out-of-band route for a path that does not carry refresh.
3. The PR body follows upstream `CONTRIBUTING.md` (Problem, Approach, Impact, Alternatives, Follow-ups). The Problem section leads with the browser publisher that has no GOP schedule, since #3256 rejected tune-in PLI for encoders that have one. It includes the measured cost from task F (method, fixture, numbers, how to reproduce), as the owner asked.

**Who does what.** The builder prepares a local port and keeps it in this repository: a patch series against a named upstream `main` commit under `openspec/changes/add-edge-keyframes/upstream/`, the `just ci` output, and `pr-draft.md`. Pushing to the `WorldTreeNetwork/moq` fork and opening the PR are reserved to Duke or a submitter he names, at all times. No builder pushes to any fork or opens anything upstream, whatever else has been decided.

**Drop condition** (in `VENDOR.md` and the tracking bead): the moq pin moves past the merge of part 1, and either part 2's `Requester` merged or the edge's WHEP of a same-edge source carries refresh. Then the same behaviour tests run against the new pin, and only if they pass are `native/vendor/moq-webrtc`, the `[patch]` lines and the `NOTICE` section deleted. The pin move rides the coordinated move the E2EE work plans (plan risk 3).

## D9. Acceptance: crate behaviour is the requirement; timings are local targets

The SHALLs in `specs/webrtc-edge/spec.md` are crate and pairing behaviour, tested deterministically (gate, causes, pairing, carry). Timings and encoder outcomes depend on the browser, the encoder, buffering and the fixture, so they are **named local acceptance targets** on this harness, not requirements.

The harness is `add-webrtc-edge/spikes/`, copied to `harness/` and extended. Its observations come in two kinds, so the before and after runs measure the same things:

**Common observations** (task H0; available on the unpatched pin and the patched build alike, used for every before/after comparison):

- a measurement-only in-process MoQ reader in the harness edge, subscribed to each WHIP broadcast the edge publishes, logging every video frame: track, group start (a keyframe, by the protocol invariant), payload bytes, media time, wall time; codec and resolution from the catalog; actual fps derived from it. **This is the one byte-counting boundary for every cost run**: MoQ frame payload bytes as the ingest published them, counted by this probe. The probe subscribes when the WHIP route is announced, before the first frame, so by D2 its own join never requests (an empty track's group-0 demand is not a join); each later subscription, the relay's included, still opens its own cursor and is judged by the ratio on its own;
- publisher-side and viewer-side RTCP stats from the browser pages every second (`outbound-rtp` `keyFramesEncoded`, `pliCount`, `firCount`, `bytesSent`, resolution, fps; `inbound-rtp` `pliCount`, `firCount`, `freezeCount`, `totalFreezesDuration`), so PLIs the publisher received are visible without patched code;
- a moving 720p Y4M fixture with a burned-in frame counter (so a decoded frame can be matched to its source frame, and fresh post-burst content can be told from buffered content), beside the two-colour fixture;
- the WHEP page timestamps the first presented frame with `requestVideoFrameCallback` against the `POST` start, and reads the frame counter;
- `harness raw` decodes the video it receives (not only the container) and prints subscribe time, first decodable frame time, and that frame's media time;
- `lossy.py --burst` with a start time and a length, logging burst end on the same clock as the edge;
- a str0m WHEP client that sends PLI on a schedule (the storm), one or several at once.

**Patch-only observations** (marked unavailable on the unpatched build; self-tested in task H2 after the patch lands):

- the edge's log of every PLI the gate sends: line, rid, cause tags, monotonic time, and the send result (`Sent`, `NoWriter`, str0m error);
- every requester call with its `Requested` result, and every egress `Ignored(Unbound)`;
- the pairing table's events (insert, replace, generation-checked remove, fail-closed fallback).

| # | Measure | Target on this fixture |
|---|---|---|
| A | WHEP `POST` → first presented frame of a WHIP-origin broadcast, per codec (H.264, VP8), 10 joins at varied phase against the period | median ≤ 2.0 s, max ≤ 2.5 s |
| B | MoQ late join: subscribe → first decodable frame; and its lag: that frame's media time against the newest media time the edge ingested at the same wall time (same track timebase) | first ≤ 1.0 s; lag ≤ 2.2 s |
| C | Player-shaped MoQ late join (moq-mux exporter), VP8 uncapped, VP9, AV1 | recorded only (H3) |
| D1 | 1.5 s blackout toward the WHEP viewer, burst at varied phase: burst end → first presented frame whose counter is after the burst; the cause-tagged viewer PLI in the edge log | ≤ 1.2 s, and a viewer-cause PLI sent |
| D2 | 1.5 s blackout toward the edge: burst end → the MoQ reader's first keyframe with a counter after the burst; the loss-cause PLI in the edge log | ≤ 1.2 s, and a loss-cause PLI sent |
| E | Storm, one viewer and then four: spacing of actual PLIs sent, causes, held-request count, `Requested` results; natural keyframes, resolution changes and `RateLimited` recorded separately | every gap between sent PLIs ≥ 1 s on the monotonic clock; held requests ≤ 1 per line; the encoder's answer recorded, not gated |
| F | Cost, on identical moving input and cap 2.5 Mbit/s: policy off, period 2 s, and saturated 1 s feedback (E's storm) | recorded (below) |

An already-fast baseline is a result, not a blocker: if a "before" number already meets its target, the "after" must still show the cause working (the cause-tagged PLI and the fresh content), and the finding says the baseline was fast. Buffered playout, NACK recovery and the period can each improve A and D1 without the viewer path working, which is why D1 needs the viewer-cause PLI and post-burst content, not just the time.

**Cost (task F) reports two different things.**

- **Keyframe byte share**: keyframe bytes over all video bytes, per run, at the probe boundary above; with mean keyframe and delta sizes, codec, fps and resolution.
- **Incremental cost of the policy**, against the policy-off run on the same input and cap, reported as two separate numbers: the **bitrate difference** over equal steady-state windows (same length, same offset after the first keyframe, probe bytes), and the **quality difference**: PSNR (and SSIM if available) of decoded frames against the source fixture, aligned by the frame counter. If alignment fails, the quality difference is reported as missing, and the PR names it as a missing result.
- Meter closures (`RateLimited`) are recorded per run.
- Neither PSNR nor a capped bitrate measures the delta-only counterfactual behind the earlier estimate; H2 is compared only through the measured keyframe/delta size ratio.

D1's earlier estimate (5 to 12 % at a 2 s period from an assumed keyframe/delta ratio) was an estimate of incremental bytes against a delta-only stream. It is kept only as hypothesis H2, to be compared with F's measurement. A pass on this fixture buys a default for this operating point, not a promise for every encoder.

Runs are on the Mac, as in the spike. Linux scale belongs to `mjolnir-rurh.7`.

**Adoption.** The trial defaults are adopted, or revised, only after F (cost), E (storm) and the latency runs A, B, D1 and D2, as ASK 4 says. Until then they are not handed to `.13`.

## Unverified hypotheses

- **H1** `refresh-join-signal`: at the pin, a new in-process cursor on a video track with `Info::refresh = Some(4)` whose newest group is over the ratio moves `Demand::wanted` past the largest group; so does the relay's first upstream subscription; a later relay-side join on lite-06 does not. Confidence medium (source reading, not run). Verification: task P4 (in-process unit test) and task B's edge trace (relay first subscription and later join, separately).
- **H2** `keyframe-ratio`: at 720p and 2.25 Mbit/s, a Chromium keyframe is 4 to 8 times a mean delta frame on moving content, and a 2 s period costs about 5 to 12 % in delta-only-equivalent bytes. Confidence low. Verification: task F, before the defaults are adopted or handed to `.13`.
- **H3** `exporter-fix`: claim 1's exporter failures on late joins come from unbounded groups. Confidence low. Verification: task C, observational.
- **H4** `vendored-unify`: the consumer with the `[patch]` line builds on macOS and Linux with one `moq-net` and every other moq crate from the pinned git source. Confidence high for resolution (the review resolved it offline), unverified for compilation. Verification: task K1, first.


> **SUPERSEDED 2026-11-26.** Not implementable. Active design is `../design.md`. Viewer PLI forwarding and in-process WHEP are withdrawn. Reviews stay the historical record.
