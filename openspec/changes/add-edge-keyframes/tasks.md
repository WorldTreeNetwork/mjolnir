# Tasks — add-edge-keyframes

No product code in this pass. Checked items are observations already captured or decisions already recorded. Each unchecked item names the failing test or the captured observation that must exist before it is checked. Work on `main`; stage only this change's files. Before any build on the Mac: `df -h /System/Volumes/Data`, a scratch `CARGO_TARGET_DIR` outside the repository, deleted afterwards. Nobody pushes to a fork or opens anything upstream except Duke or a submitter he names (design D8).

## Spike

- [x] `upstream-keyframes`: refuted. Upstream `main` `9901b71` (2026-11-26T02:29Z) asks a WHIP publisher only for its first keyframe and a timeline step, drops a viewer's PLI/FIR, and has no option or open issue/PR. `main` has `Refresh { ratio, interval }`, `Demand::poll_refresh` and public `Subscriber::refresh()`; the pin does not. Evidence: `spikes/upstream-keyframes.md`, `spikes/evidence/upstream-keyframes.txt`.

## Review

- [x] Advise 2026-11-25 (Astra): send-back. `reviews/2026-11-25-advise.md`, `reviews/2026-11-25-blind-take.md`. This revision answers findings 1–7.
- [x] Advise 2026-11-25, second read (Astra): send-back, narrowly. `reviews/2026-11-25-advise-2.md`. This revision answers its four edits (source binding, gate defaults and parking, loss forwarding, executable order).
- [ ] Fresh advise after the 2026-11-26 withdrawal of in-process WHEP and viewer PLI forwarding, by the same reviewer. Ingest policy is unchanged. No product code until that accept.

## Order

K0 → K1 → H0 → H1 (the baseline, harness still on git `moq-webrtc`) → K2 → K3 → K4 (harness switched to the vendored crate) → P1–P9 → H2 (patch-only self-test) → D3a–D3e → A–F → adopt → U1–U4. A box is not started before the boxes it follows are checked.

## Feasibility first (before any harness or patch work)

- [ ] K0. Relay baseline in `harness/logs/relay-baseline.txt`: `git rev-parse HEAD`; `shasum -a 256` of `native/mjolnir_relay/Cargo.toml`, `native/mjolnir_relay/Cargo.lock`, `native/Cargo.lock`, `openspec/changes/add-call-e2ee/spikes/rust/Cargo.lock`, `openspec/changes/add-webrtc-edge/spikes/rust/Cargo.lock`; `cargo metadata --locked --format-version 1 --manifest-path native/mjolnir_relay/Cargo.toml` succeeds; and only after that, `cargo tree --locked -i moq-webrtc` in the relay, whose "package not found" is the expected result.
- [ ] K1. Feasibility (H4), in a scratch directory outside the repository, with the pristine vendored crate (D5 layout, manifest per D5's table, no patch). Two subjects, each on macOS and on the Framework laptop (Linux, toolchain 1.95.0), recorded separately in `harness/logs/k1-feasibility.txt`:
  - **K1a, the consumer.** A copy of the spike consumer with the `[patch]` line pointing at the pristine crate, and its `mjolnir-relay` path dependency rewritten to this checkout's `native/mjolnir_relay` (the spike's relative path does not resolve from a scratch directory). Write its lock once with an unlocked resolution, then `cargo build --locked`. Record the `cargo metadata` package ids (`moq-webrtc` a path id; every other moq crate `git+https://github.com/moq-dev/moq?rev=4a6f52248#4a6f5224…`; one `moq-net 0.3.10`), the build time, and no unused-patch warning.
  - **K1b, the vendored crate.** Write its own lock once, then `cargo test --locked` in its workspace. Record test counts and failures.

  If either subject fails on either platform, stop and report on the bead; the carry mechanism (ASK 3) is reopened.

## Harness and the "before" (unpatched pin; the harness still uses git `moq-webrtc`)

- [ ] H0. Copy `add-webrtc-edge/spikes/` to `harness/` and add the **common observations** of design D9 only: the in-process measurement probe (per-frame track, group start, payload bytes, media time, wall time; the one byte-counting boundary), browser RTCP stats every second on both pages, the moving 720p fixture with a burned-in frame counter, the first-presented-frame callback with counter, decoding `harness raw` with subscribe / first-decodable / media-time lines, `lossy.py --burst` on the edge's clock, and the str0m storm client (one or several). First observation: `harness/logs/selftest-common.log` shows each common field once against the unpatched edge. Patch-only fields (gate PLI log, requester results, `Ignored(Unbound)`, pairing events) are listed there as unavailable on this build.
- [ ] H1. Before numbers for D9 rows A, B, C, D1, D2 and F (policy off) on the unpatched pin, from common observations only: `harness/logs/before-*.log`. Captured before K4 switches the harness. A baseline that already meets its target is recorded as a result; the after run must then still show the cause working (D9).

## Vendor and switch

- [ ] K2. `scripts/check-vendored-moq-webrtc.sh`, written before the vendor commit and failing because the directory does not exist (capture that run). It fetches `rs/moq-webrtc` and the root licence files at `4a6f522` (cargo git checkout if present, else a scratch shallow fetch outside the repository), reverses every file in `patches/`, and checks: `src/`, `CHANGELOG.md`, `MIGRATE.md`, `clippy.toml` identical; `LICENSE-MIT` and `LICENSE-APACHE` identical to the moq root's; the manifest equal to D5's table (dependency sources, versions, `default-features`, `features`, optional, `[features]`, removed `workspace-hack` and lints); every modified file and the manifest carry the modification notice (D6).
- [ ] K3. Vendor commit: the pristine crate into `native/vendor/moq-webrtc/` with its committed lock (from K1b), licence files, manifest notice, `VENDOR.md` (base, packaging-difference table, outbound licence line from ASK 2, tracking bead, drop condition). K2 passes with an empty `patches/`.
- [ ] K4. Only after H1: the harness consumer gets the `[patch]` line and its committed lock. A script beside it fails before the line (git `moq-webrtc`) and passes after: `cargo metadata --locked` package ids as in K1a, `cargo tree --locked -d` lists no moq crate, no unused-patch warning.
- [ ] K5. After K3, K4, P9 and every later commit touching Cargo files: rerun K0. `git diff --exit-code <K0 commit> -- native/mjolnir_relay/` is empty and every hash equal. Record in `harness/logs/relay-after.txt`. An unrelated concurrent edit on those paths by another agent is identified by `git log` and reported, not counted as this change.

## Patch (in `native/vendor/moq-webrtc`, tests first, each failing before its code)

- [ ] P1. Gate, a pure struct beside `IngestOrder`: send when the floor allows; one held request per line with cause tags; a keyframe (the first included) cancels; overlapping causes (startup, step, period, loss, join) between two sends produce exactly one send tagged with all of them; the pinned startup and step paths are inside the cooldown when enabled. There is no viewer cause.
- [ ] P1b. Defaults and validation: `Keyframes::default().floor == 1 s`; `Keyframes { enabled: true, ..Default::default() }` spaces two requests by 1 s; `whip::accept` returns `Error::InvalidKeyframes` for an enabled zero floor and for an enabled zero period.
- [ ] P2. Unanswered request: with period 2 s and an ignored PLI at 2 s, the next period deadline is 4 s; a deadline already in the past is never returned twice.
- [ ] P3. No receiver or refused writer: a send attempted before the line has a receive stream, with no writer, or refused by str0m (`NoReceiverSource`, `NotReceivingDirection`) leaves the request held, does not move `last_sent`, does not end the session, and is counted. With a paused clock, 10 s elapse with no RTP and the line's timer fires once, then stays disarmed. A first delta then releases one PLI at once; in another run a first keyframe cancels it. A strictly future deadline from another cause re-arms it. A line without negotiated PLI never sends.
- [ ] P4. Join (H1): `Info::refresh == Some(4)` on video tracks when set, `None` by default; an in-process join over the ratio requests once; first and later joins under the ratio request nothing; an empty track's group-0 demand requests nothing; the observer's first reading requests nothing.
- [ ] P5. Loss: a usable discontinuous delta (after the line's last keyframe) requests and is forwarded; an ineligible one (on a line with no keyframe yet, and one older than the last keyframe) requests and is dropped by the pinned admission; with `on_loss` off neither requests and forwarding is unchanged.
Withdrawn 2026-11-26 (relay-authorized media): P6 requester API, P6b egress binding, D3a–D3e pairing table, and the `.13` handoff that said a paired WHEP plays in process. Do not implement them.

- [ ] P6. The patch does not add `Response::keyframes`, a WHEP requester, or `whep::Request::source`. A unit test sends a viewer PLI into pinned egress and observes it dropped, as at the pin.
- [ ] P7. Disabled policy: every upstream test at the pin passes; a new test drives startup, a step, non-contiguous frames and a requester call with `Request::new` and observes exactly the pinned PLIs and the pinned forwarding. Total test count is K1b's plus the new ones (`harness/logs/p7-tests.txt`).
- [ ] P8. Session wiring: one `select!` arm whose deadline is the earliest armed deadline (REMB, period, gate; a disarmed line contributes none); a paused-clock test of that function.
- [ ] P9. Commit the patch on its own, with the modification notice on every changed file; export `patches/0001-edge-keyframes.patch` with `git format-patch`; K2 passes; clippy at the crate's own level shows no new warnings.
- [ ] H2. Patch-only self-test, on the switched harness: `harness/logs/selftest-patch.log` shows the gate PLI log (cause tags, send result), requester results, an `Ignored(Unbound)` and each pairing event once.

## Harness pairing (embedder side, in the harness edge)

- [ ] D3. Negative control: bob's WHEP plays alice through the relay; bob's PLIs do not increment alice's viewer-cause count (there is no viewer cause). `after-D3.log`.

## After (D9 local targets)

- [ ] A. WHEP `POST` → first presented frame, H.264 and VP8, 10 joins at varied phase: median ≤ 2.0 s, max ≤ 2.5 s. `after-A.log` beside `before-A.log`.
- [ ] B. MoQ late join, 10 joins: first decodable frame ≤ 1.0 s after subscribe; lag against the probe's newest media time at that wall time ≤ 2.2 s. Separately, over a real relay hop with the negotiated wire version recorded: the edge trace for the relay's first upstream subscription and for a later relay-side join while it stays open (H1). `after-B.log`.
- [ ] C. Exporter late join (VP8 uncapped, VP9, AV1): recorded in `after-C.log`. If not content-ok, a bead under `mjolnir-rurh.13` (H3).
- [ ] D1. Viewer-side 1.5 s blackout at varied phase, same relayed WHEP route as the before run: record time to the first presented frame with a post-burst counter. A viewer-cause PLI is not required. The 1.2 s figure is an observation against the ingest cadence, not a pass gate. `after-D1.log`.
- [ ] D2. Publisher-side 1.5 s blackout: the MoQ reader's first post-burst keyframe ≤ 1.2 s after the burst end; a loss-cause PLI in the edge log. `after-D2.log`.
- [ ] E. Storm, one viewer then four, 20 s at 2.5 Mbit/s cap: every gap between sent PLIs ≥ 1 s on the monotonic clock; held requests ≤ 1 per line; `Requested` results counted; natural keyframes, resolution changes and `RateLimited` recorded separately. `after-E.log`.
- [ ] F. Cost on identical moving input and cap, all three runs counted at the same probe boundary (MoQ frame payload bytes as the ingest published them): policy off, period 2 s, saturated 1 s feedback. Report separately (a) keyframe byte share, mean keyframe and delta sizes, codec, fps, resolution; (b) the bitrate difference against policy off over equal steady-state windows; (c) the quality difference: PSNR (and SSIM if available) aligned by frame counter, or "quality difference missing" stated explicitly. `RateLimited` per run. Compare the keyframe/delta size ratio with H2. `after-F.log`.
- [ ] F-PR. Turn F into `upstream/cost.md` for the upstream PR body: method, fixture (how it is generated, resolution, frame rate, content), encoder and browser versions, cap, the counting boundary, the numbers for each run (bitrate and quality differences separately), any missing result named as missing, and the commands to reproduce from a clean checkout. It is written so it can be pasted into the PR without editing.
- [ ] Adopt or revise the trial defaults. Depends on F, E, A, B, D1 and D2 all being checked (ASK 4: adopt after measurement). Record the decision and the numbers on the bead. Only then hand the defaults to `.13`.
- [ ] `harness/finding.md`: before/after table with numbers and links to every log.

## Upstream (local preparation only)

- [ ] U1. Port to upstream `main` per design D8 parts 1 and 2, as a patch series against a named `main` commit, kept in this repository under `upstream/` (`git format-patch` output plus the base commit id), with the `just ci` log. Retrievable from this repository alone. No push, no PR.
- [ ] U2. `upstream/pr-draft.md` (Problem, Approach, Impact, Alternatives, Follow-ups), with `upstream/cost.md` included as its cost section. Depends on F-PR and U1; not started before both are checked.
- [ ] U3. Tracking bead (child of `mjolnir-rurh`) with the drop condition from design D8, the rule that the behaviour tests run again at the pin move before the carry is removed, and the rule that only Duke or his named submitter pushes to the `WorldTreeNetwork/moq` fork or opens the PR. Linked from `VENDOR.md`.
- [ ] U4. `NOTICE` gains a "Vendored third-party code" section (path, `MIT OR Apache-2.0`, Copyright (c) 2023 Luke Curley and the moq authors). `CLAUDE.md` gets one line pointing at `native/vendor/moq-webrtc/VENDOR.md`.
- [ ] Handoff note on `mjolnir-rurh.13`: the `[patch]` line; WHEP stays on the viewer's relay token; no pairing table and no in-process play; adopted defaults with F's numbers.

## ASK (answered by Duke 2026-11-25: "for contract, i agree with those - wtn fork, measure cost and include in the pr, license matches upstream")

- [x] **ASK 1** Upstream submission. Recommendation was: Duke opens the prepared PR from the Foundation fork; the builder supplies the reproducible local port, CI result and draft. Answered 2026-11-25: "wtn fork". The PR comes from a `WorldTreeNetwork/moq` fork. Pushing to it and opening the PR stay with Duke or a submitter he names. Added from the same answer: "measure cost and include in the pr" (task F-PR; U2 depends on it).
- [x] **ASK 2** Outbound licence. Recommendation was: approve `MIT OR Apache-2.0` for the Foundation-authorised patch. Answered 2026-11-25: "license matches upstream". Recorded in design D6 and, at K3, in `VENDOR.md`.
- [x] **ASK 3** Carry mechanism. Recommendation was: vendor only `moq-webrtc` with the consumer-local patch and keep the pin. Answered 2026-11-25: "for contract, i agree with those". Reopened only if K1 fails.
- [x] **ASK 4** Edge defaults and residual cost. Recommendation was: trial 2 s, ratio 4, loss requests on, one 1 s floor per eligible source line; adopt after F and the latency and storm runs; one viewer can sustain that floor, quality may fall under the cap, and cost adds across lines. Answered 2026-11-25: "for contract, i agree with those". The defaults stay provisional until the adopt task above.
- [x] **ASK 5** Deltas after loss. Recommendation was: keep forwarding usable deltas while the keyframe is awaited (brief corruption possible). Answered 2026-11-25: "for contract, i agree with those".
