# Tasks — add-edge-keyframes

No product code in this pass. Checked items are observations already captured. Each unchecked item names the failing test or the captured observation that has to exist before it is checked. Work on `main`; stage only this change's files.

## Spike

- [x] `upstream-keyframes`: refuted. Upstream `main` `9901b71` (2026-11-26T02:29Z) asks a WHIP publisher only for its first keyframe and a timeline step, drops a viewer's PLI/FIR, and has no option or open issue/PR. Related: #2284 closed via #3256 (2 s GOP verdict), #6270 declined in favour of `track::Info::refresh`. `main` has `Refresh { ratio, interval }`, `Demand::poll_refresh` and public `Subscriber::refresh()`; the pin does not. Evidence: `spikes/upstream-keyframes.md`, `spikes/evidence/upstream-keyframes.txt`.

## Harness and the "before" (captured first, against the unpatched pin)

- [ ] H0. Copy `add-webrtc-edge/spikes/` (scripts, pages, `rust/`, `lossy.py`, `analyze.py`) to `harness/` and extend it as design D8 lists: first-decoded-frame timestamp on the WHEP page, publisher and viewer RTCP stats every second, subscribe / first-frame / lag lines from `harness raw`, `lossy.py --burst`, a moving 720p fixture, and a str0m PLI-storm WHEP client. The harness workspace keeps its own `[workspace]` and lockfile, seeded from the spike's lockfile. First observation: `harness/logs/selftest.log` shows each new field printed once against a run of the unpatched edge.
- [ ] H1. Capture the before numbers for D8 rows A, B, C, D1 and D2 against the unpatched pin (no `[patch]` line yet): `harness/logs/before-{A,B,C,D1,D2}.log`. These are the failing observations: the after thresholds must not already hold. If one already holds, stop and record it as a finding on the bead before writing code for that cause.

## Carry (vendored crate; the relay stays byte-identical)

- [ ] C0. Record the relay baseline in `harness/logs/relay-baseline.txt`: `git rev-parse HEAD`, `shasum -a 256 native/mjolnir_relay/Cargo.toml native/mjolnir_relay/Cargo.lock native/Cargo.lock openspec/changes/add-call-e2ee/spikes/rust/Cargo.lock openspec/changes/add-webrtc-edge/spikes/rust/Cargo.lock`, and `cargo tree --locked -i moq-webrtc --manifest-path native/mjolnir_relay/Cargo.toml` (expected: not found).
- [ ] C1. Write `scripts/check-vendored-moq-webrtc.sh` first. It fetches `rs/moq-webrtc` at `4a6f522` (from the cargo git checkout if present, else a scratch shallow fetch outside the repo), reverses every file in `native/vendor/moq-webrtc/patches/`, and diffs `src/`. It fails today because the directory does not exist (capture that run). Then vendor the pristine crate in its own commit: `src/` copied unchanged, `LICENSE-MIT` and `LICENSE-APACHE` from the moq root at `4a6f522`, the manifest written out as design D4 says, its own `[workspace]`, `VENDOR.md`. The script passes with an empty `patches/`.
- [ ] C2. The pristine vendored crate's own tests pass where it now lives: `cargo test --locked` in `native/vendor/moq-webrtc` with toolchain 1.95.0, on the Mac and on the Framework laptop (Linux). Record test counts in `harness/logs/c2-pristine-tests.txt`. A test that needs something the dropped `workspace-hack` provided gets the dependency added explicitly, never skipped.
- [ ] C3. Prove nothing else moved: rerun C0's commands after C1 and after every later commit that touches Cargo files; `git diff --exit-code <C0 commit> -- native/mjolnir_relay/` must be empty and every hash equal. Record in `harness/logs/relay-after.txt`.
- [ ] C4. Add the `[patch."https://github.com/moq-dev/moq"] moq-webrtc = { path = … }` line to `harness/rust/Cargo.toml` only. Test, in a script beside the harness: `cargo tree --locked -i moq-webrtc` names the vendored path, `cargo tree --locked -d` lists no moq crate, and `cargo build` output contains no `was not used in the crate graph` warning. The script fails before the line is added (moq-webrtc from git) and passes after.

## Patch (in `native/vendor/moq-webrtc`, tests first)

- [ ] P1. Keyframe gate, a pure struct beside `IngestOrder`. Tests, written first and failing until the module exists: period fires after `period` with no keyframe; a keyframe resets the period; requests inside `min_interval` coalesce into one at the window's end; a keyframe cancels a held request; `Keyframes::default()` never fires; first-keyframe and timeline-step requests are not gated.
- [ ] P2. `Keyframes` on `whip::Request`, defaulting off. Test: the existing `whip.rs` tests pass unchanged, and a new test shows `Request::new(..).keyframes` equals `Keyframes::default()`.
- [ ] P3. Video tracks carry `Info::refresh`. Test modelled on `tracks_inherit_the_configured_max_age` (`ingest.rs`): with `refresh: Some(4)` the `0.vp8` track's info has `refresh == Some(4)`; with the default it is `None`. Fails first.
- [ ] P4. Join cause (hypothesis H1). Test: an in-process `IngestSink` with `refresh: Some(4)`, a group whose deltas exceed four keyframes, then a new subscriber at the live edge: the sink reports a demand change past the largest group to the session's gate. A second test with deltas under the ratio reports none. Fails first.
- [ ] P5. Loss cause. Test on the gate's input mapping: a non-keyframe frame with `contiguous == false` yields one request when `on_loss` is set and none when it is not.
- [ ] P6. Viewer path. `whip::Response::keyframes()` returns a weak `Requester`; `whep::Request::keyframes` is honoured on `Event::KeyframeRequest`. Tests: a counting requester sees exactly one call per PLI and per FIR event; `request()` after the WHIP session ends returns without effect and does not keep the session alive.
- [ ] P7. Session wiring: one `select!` arm for the period deadline, the gate release, demand changes and requester messages. Test with a paused clock on the arm's deadline function (earliest of REMB, period and release). Every upstream test at the pin still passes; the total is C2's count plus the new tests (`harness/logs/p7-tests.txt`).
- [ ] P8. Commit the patch on its own and export it to `patches/0001-edge-keyframes.patch` with `git format-patch`. `scripts/check-vendored-moq-webrtc.sh` passes. Clippy at the crate's own lint level shows no new warnings.

## After (the contrast; D8 thresholds)

- [ ] A. WHEP join of a WHIP-origin broadcast, H.264 and VP8, 10 joins each: median ≤ 2.0 s, max ≤ 2.5 s. `harness/logs/after-A.log` beside `before-A.log`.
- [ ] B. MoQ late join, 10 joins: first decodable frame ≤ 1.0 s after subscribe; its lag behind live ≤ 2.2 s. `after-B.log`.
- [ ] C. moq-mux exporter late join on VP8 uncapped, VP9, AV1: recorded in `after-C.log`. If not content-ok, file a bead under `mjolnir-rurh.13` for the playback check (H3), and do not block here.
- [ ] D1. 1.5 s blackout toward the WHEP viewer: next decoded frame ≤ 1.2 s after the burst; publisher `pliCount` rose. `after-D1.log`.
- [ ] D2. 1.5 s blackout toward the edge: the MoQ reader's next keyframe ≤ 1.2 s after the burst. `after-D2.log`.
- [ ] D3. Cross-room: a WHEP session with an `r2` token for the same broadcast path sends PLIs; alice's `pliCount` does not move from them. `after-D3.log`.
- [ ] E. Storm client for 20 s at 2.5 Mbit/s cap: publisher `keyFramesEncoded` rises by ≤ 21 plus resolution changes; the WHIP session is not `RateLimited`. `after-E.log`.
- [ ] F. Keyframe cost on the moving fixture: period off, 2 s, and the E storm; report keyframe share of video bytes and mean keyframe/delta size (hypothesis H2). `after-F.log`. If the 2 s share exceeds 15 %, raise it as an ASK on this file before fold.
- [ ] Write `harness/finding.md`: the before/after table with numbers and links to the logs.

## Upstream (prepared here, not opened)

- [ ] U1. Port to upstream `main` in a scratch clone outside this repo, as design D7 parts 1 and 2: `Refresh { ratio, interval }` with `Demand::poll_refresh` on ingest, `Subscriber::refresh()` plus the optional `Requester` on egress. Record the base commit, `just ci` output and the PR body draft (Problem, Approach, Impact, Alternatives, Follow-ups) in `upstream/pr-draft.md`. Do not push or open anything until the ASKs below are answered.
- [ ] U2. Create the tracking bead (child of `mjolnir-rurh`) with the drop condition from design D7, and link it from `VENDOR.md`. When the PR exists, add its URL to the bead and `VENDOR.md`.
- [ ] U3. `NOTICE` gains a "Vendored third-party code" section naming `native/vendor/moq-webrtc` (`MIT OR Apache-2.0`, Copyright the moq authors). `CLAUDE.md` gets one line pointing at `native/vendor/moq-webrtc/VENDOR.md`.
- [ ] Handoff note on `mjolnir-rurh.13`: the `[patch]` line and the WHIP/WHEP pairing table it must carry into `native/mjolnir_rtc`, keyed by verified root and broadcast.

## ASK (Duke has not confirmed these)

- [ ] **ASK** Who opens the upstream PR, and from which account. Recommendation: the branch lives on a `WorldTreeNetwork/moq` fork, and Duke opens the PR from his own GitHub account so a person answers review. The agent prepares the branch and body (U1) and states in the PR that it was written with an AI agent, as upstream PRs already do.
- [ ] **ASK** Outbound licence of the patch: the Foundation offers it `MIT OR Apache-2.0`, the crate's licence. Recommendation: yes. Without it the vendored copy and the upstream PR cannot carry it.
- [ ] **ASK** Vendored copy in `native/vendor/moq-webrtc`, not a fork with every moq crate patched to it. Recommendation: vendored (design D4: one crate replaced, one `moq-net`, no second remote at build time).
- [ ] **ASK** Edge defaults: period 2 s, refresh ratio 4, loss requests on, throttle 1 s per line. Recommendation: yes, revisited after task F.
- [ ] **ASK** Deltas after loss are forwarded until the keyframe arrives (brief corruption), not held back (brief freeze). Recommendation: forward, as today; revisit with real viewers.
