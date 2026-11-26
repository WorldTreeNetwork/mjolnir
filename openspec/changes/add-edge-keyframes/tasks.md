# Tasks — add-edge-keyframes

No product code in this pass. Checked items are observations already captured or decisions already recorded. Each unchecked item names the failing test or the captured observation that must exist before it is checked. Work on `main`; stage only this change's files. Before any build on the Mac: `df -h /System/Volumes/Data`, a scratch `CARGO_TARGET_DIR` outside the repository, deleted afterwards. Nobody pushes to a fork or opens anything upstream except Duke or a submitter he names (design D8).

## Spike

- [x] `upstream-keyframes`: refuted. Upstream `main` `9901b71` (2026-11-26T02:29Z) asks a WHIP publisher only for its first keyframe and a timeline step, drops a viewer's PLI/FIR, and has no option or open issue/PR. `main` has `Refresh { ratio, interval }`, `Demand::poll_refresh` and public `Subscriber::refresh()`; the pin does not. Evidence: `spikes/upstream-keyframes.md`, `spikes/evidence/upstream-keyframes.txt`.

## Review

- [x] Advise 2026-11-25 (Astra): send-back. `reviews/2026-11-25-advise.md`, `reviews/2026-11-25-blind-take.md`. This revision answers findings 1–7.
- [ ] Fresh advise after this revision, by the same reviewer.

## Feasibility first (before any harness or patch work)

- [ ] K0. Relay baseline in `harness/logs/relay-baseline.txt`: `git rev-parse HEAD`; `shasum -a 256` of `native/mjolnir_relay/Cargo.toml`, `native/mjolnir_relay/Cargo.lock`, `native/Cargo.lock`, `openspec/changes/add-call-e2ee/spikes/rust/Cargo.lock`, `openspec/changes/add-webrtc-edge/spikes/rust/Cargo.lock`; `cargo metadata --locked --format-version 1 --manifest-path native/mjolnir_relay/Cargo.toml` succeeds; and only after that, `cargo tree --locked -i moq-webrtc` in the relay, whose "package not found" is the expected result.
- [ ] K1. Pristine consumer build (H4). In a scratch directory outside the repository: the pristine vendored crate (D5 layout, manifest per D5's table, no patch) and a copy of the spike consumer with the `[patch]` line. Write both locks once with an unlocked resolution, then `cargo build --locked` and `cargo test --locked` of the vendored crate on macOS and on the Framework laptop (Linux, toolchain 1.95.0). Record in `harness/logs/k1-feasibility.txt`: the `cargo metadata` package ids (`moq-webrtc` a path id; every other moq crate `git+https://github.com/moq-dev/moq?rev=4a6f52248#4a6f5224…`; one `moq-net 0.3.10`), test counts, build times, and no unused-patch warning. If it fails on either platform, stop and report on the bead; the carry mechanism (ASK 3) is reopened.
- [ ] K2. `scripts/check-vendored-moq-webrtc.sh`, written before the vendor commit and failing because the directory does not exist (capture that run). It fetches `rs/moq-webrtc` and the root licence files at `4a6f522` (cargo git checkout if present, else a scratch shallow fetch outside the repository), reverses every file in `patches/`, and checks: `src/`, `CHANGELOG.md`, `MIGRATE.md`, `clippy.toml` identical; `LICENSE-MIT` and `LICENSE-APACHE` identical to the moq root's; the manifest equal to D5's table (dependency sources, versions, `default-features`, `features`, optional, `[features]`, removed `workspace-hack` and lints); every modified file and the manifest carry the modification notice (D6).
- [ ] K3. Vendor commit: the pristine crate into `native/vendor/moq-webrtc/` with its committed lock (from K1), licence files, manifest notice, `VENDOR.md` (base, packaging-difference table, outbound licence line from ASK 2, tracking bead, drop condition). K2 passes with an empty `patches/`.
- [ ] K4. The harness consumer (H0's copy) gets the `[patch]` line and its committed lock. A script beside it fails before the line (git `moq-webrtc`) and passes after: `cargo metadata --locked` package ids as in K1, `cargo tree --locked -d` lists no moq crate, no unused-patch warning.
- [ ] K5. After K3, K4, P9 and every later commit touching Cargo files: rerun K0. `git diff --exit-code <K0 commit> -- native/mjolnir_relay/` is empty and every hash equal. Record in `harness/logs/relay-after.txt`. An unrelated concurrent edit on those paths by another agent is identified by `git log` and reported, not counted as this change.

## Harness and the "before" (unpatched pin)

- [ ] H0. Copy `add-webrtc-edge/spikes/` to `harness/` and extend it as design D9 lists: per-PLI and per-requester-call edge log, per-frame ingest log (type, bytes, codec, resolution, media time, arrival), moving 720p fixture with a burned-in frame counter, first-presented-frame callback with counter on the WHEP page, decoding `harness raw` with subscribe / first-decodable / media-time lines, `lossy.py --burst` on the edge's clock, and the str0m storm client (one or several). First observation: `harness/logs/selftest.log` shows each new field once against the unpatched edge.
- [ ] H1. Before numbers for D9 rows A, B, C, D1, D2 and F (policy off) on the unpatched pin: `harness/logs/before-*.log`. A baseline that already meets its target is recorded as a result; the after run must then still show the cause working (D9).

## Patch (in `native/vendor/moq-webrtc`, tests first, each failing before its code)

- [ ] P1. Gate, a pure struct beside `IngestOrder`: send when the floor allows; one held request per line with cause tags; a keyframe cancels; overlapping causes (startup, step, period, loss, join, viewer) between two sends produce exactly one send tagged with all of them; the pinned startup and step paths are inside the cooldown when enabled.
- [ ] P2. Unanswered request: with period 2 s and an ignored PLI at 2 s, the next period deadline is 4 s; a deadline already in the past is never returned twice.
- [ ] P3. No receiver: a send attempted before the line has a receive stream, or one str0m refuses with `NoReceiverSource` or `NotReceivingDirection`, leaves the request held, does not move `last_sent`, does not end the session, and is counted; a line without negotiated PLI never sends.
- [ ] P4. Join (H1): `Info::refresh == Some(4)` on video tracks when set, `None` by default; an in-process join over the ratio requests once; first and later joins under the ratio request nothing; an empty track's group-0 demand requests nothing; the observer's first reading requests nothing.
- [ ] P5. Loss: a non-keyframe frame with `contiguous == false` requests when `on_loss` is set, not otherwise, and is forwarded either way.
- [ ] P6. Requester and pairing (crate side): `Response::keyframes()` is `Some` for WHIP and `None` for WHEP; `Retired` after the session ends, including while its broadcast lingers; `Ignored(Ambiguous)` with two video lines; `Ignored(WrongTrack)` and `Ignored(WrongInstance)`; `Ignored(Disabled)` with the policy off; repeated calls coalesce (one pending wakeup); egress forwards PLI and FIR on its video line naming the served track and instance, and drops audio-line and pre-rendition requests.
- [ ] P7. Disabled policy: every upstream test at the pin passes; a new test drives startup, a step, non-contiguous frames and a requester call with `Request::new` and observes exactly the pinned PLIs. Total test count is K1's plus the new ones (`harness/logs/p7-tests.txt`).
- [ ] P8. Session wiring: one `select!` arm whose deadline is the earliest of REMB, period and gate; a paused-clock test of that function.
- [ ] P9. Commit the patch on its own, with the modification notice on every changed file; export `patches/0001-edge-keyframes.patch` with `git format-patch`; K2 passes; clippy at the crate's own level shows no new warnings.

## Harness pairing (embedder side, in the harness edge)

- [ ] D3a. Table keyed by (full verified root, canonical root-relative path), entries holding a generation; pairing only after token verification and path grant on both legs. Test: two active rooms with the same broadcast path, each with publisher and viewer; per-session dispatch counters show each viewer reaching only its own publisher, both positive in the same run. `after-D3a.log`.
- [ ] D3b. Stale viewer: replace the publisher at the same root and path; the old viewer's call returns `Retired`; the new publisher's counter does not move from it. `after-D3b.log`.
- [ ] D3c. Late cleanup: process the old session's end after the replacement is inserted; the entry still names the replacement. Unit test in the harness edge.

## After (D9 local targets)

- [ ] A. WHEP `POST` → first presented frame, H.264 and VP8, 10 joins at varied phase: median ≤ 2.0 s, max ≤ 2.5 s. `after-A.log` beside `before-A.log`.
- [ ] B. MoQ late join, 10 joins: first decodable frame ≤ 1.0 s after subscribe; lag against the edge's newest ingested media time at that wall time ≤ 2.2 s. Separately, the edge trace for the relay's first upstream subscription and for a later relay-side join while it stays open (H1). `after-B.log`.
- [ ] C. Exporter late join (VP8 uncapped, VP9, AV1): recorded in `after-C.log`. If not content-ok, a bead under `mjolnir-rurh.13` (H3).
- [ ] D1. Viewer-side 1.5 s blackout at varied phase: first presented frame with a post-burst counter ≤ 1.2 s after the burst end; a viewer-cause PLI in the edge log. `after-D1.log`.
- [ ] D2. Publisher-side 1.5 s blackout: the MoQ reader's first post-burst keyframe ≤ 1.2 s after the burst end; a loss-cause PLI in the edge log. `after-D2.log`.
- [ ] E. Storm, one viewer then four, 20 s at 2.5 Mbit/s cap: every gap between sent PLIs ≥ 1 s on the monotonic clock; held requests ≤ 1 per line; `Requested` results counted; natural keyframes, resolution changes and `RateLimited` recorded separately. `after-E.log`.
- [ ] F. Cost on identical moving input and cap: policy off, period 2 s, saturated 1 s feedback. Report separately (a) keyframe byte share, mean keyframe and delta sizes, codec, fps, resolution, observed bitrate, and (b) incremental cost of the policy against policy off: PSNR (and SSIM if available) aligned by frame counter, or "quality cost unmeasured" stated explicitly. `RateLimited` per run. Compare with H2. `after-F.log`.
- [ ] F-PR. Turn F into `upstream/cost.md` for the upstream PR body: method, fixture (how it is generated, resolution, frame rate, content), encoder and browser versions, cap, the numbers for each run, and the commands to reproduce from a clean checkout. It is written so it can be pasted into the PR without editing.
- [ ] Adopt or revise the trial defaults from F and E (ASK 4 says adopt after measurement). Record the decision and the numbers on the bead. Only then hand the defaults to `.13`.
- [ ] `harness/finding.md`: before/after table with numbers and links to every log.

## Upstream (local preparation only)

- [ ] U1. Port to upstream `main` per design D8 parts 1 and 2, as a patch series against a named `main` commit, kept in this repository under `upstream/` (`git format-patch` output plus the base commit id), with the `just ci` log. Retrievable from this repository alone. No push, no PR.
- [ ] U2. `upstream/pr-draft.md` (Problem, Approach, Impact, Alternatives, Follow-ups), with `upstream/cost.md` included as its cost section. Depends on F-PR and U1; not started before both are checked.
- [ ] U3. Tracking bead (child of `mjolnir-rurh`) with the drop condition from design D8, the rule that the behaviour tests run again at the pin move before the carry is removed, and the rule that only Duke or his named submitter pushes to the `WorldTreeNetwork/moq` fork or opens the PR. Linked from `VENDOR.md`.
- [ ] U4. `NOTICE` gains a "Vendored third-party code" section (path, `MIT OR Apache-2.0`, Copyright (c) 2023 Luke Curley and the moq authors). `CLAUDE.md` gets one line pointing at `native/vendor/moq-webrtc/VENDOR.md`.
- [ ] Handoff note on `mjolnir-rurh.13`: the `[patch]` line, the pairing table and its generation rule, and the adopted defaults with F's numbers.

## ASK (answered by Duke 2026-11-25: "for contract, i agree with those - wtn fork, measure cost and include in the pr, license matches upstream")

- [x] **ASK 1** Upstream submission. Recommendation was: Duke opens the prepared PR from the Foundation fork; the builder supplies the reproducible local port, CI result and draft. Answered 2026-11-25: "wtn fork". The PR comes from a `WorldTreeNetwork/moq` fork. Pushing to it and opening the PR stay with Duke or a submitter he names. Added from the same answer: "measure cost and include in the pr" (task F-PR; U2 depends on it).
- [x] **ASK 2** Outbound licence. Recommendation was: approve `MIT OR Apache-2.0` for the Foundation-authorised patch. Answered 2026-11-25: "license matches upstream". Recorded in design D6 and, at K3, in `VENDOR.md`.
- [x] **ASK 3** Carry mechanism. Recommendation was: vendor only `moq-webrtc` with the consumer-local patch and keep the pin. Answered 2026-11-25: "for contract, i agree with those". Reopened only if K1 fails.
- [x] **ASK 4** Edge defaults and residual cost. Recommendation was: trial 2 s, ratio 4, loss requests on, one 1 s floor per eligible source line; adopt after F and the latency and storm runs; one viewer can sustain that floor, quality may fall under the cap, and cost adds across lines. Answered 2026-11-25: "for contract, i agree with those". The defaults stay provisional until the adopt task above.
- [x] **ASK 5** Deltas after loss. Recommendation was: keep forwarding usable deltas while the keyframe is awaited (brief corruption possible). Answered 2026-11-25: "for contract, i agree with those".
