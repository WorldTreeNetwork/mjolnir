# Independent implementation review — b33ddf24

**Code: SEND-BACK. Adoption: NOT READY, independently of the code verdict.**

Reviewed `b33ddf24`, including the full carried patch, accepted `6abb5065` contract and latest accepting review, active proposal/design/spec/tasks, checker, harness and committed before/after evidence. No implementation, production, upstream publication or harness edits. Builder's concurrent harness work is excluded from this verdict. `.12` remains open; this review does not unblock `.13` or `.15`.

## Required code fixes

### R1 — P1: an expired timer can spin and starve RTP

`native/vendor/moq-webrtc/src/session.rs:470–476` takes the due deadline, then calls `note(Period, now)`, which installs another deadline of `now` (`keyframe.rs:106–111`). `flush_gate` returns before consuming/disarming it whenever `ready` is false (`session.rs:506–507`). A video line without negotiated PLI therefore spins forever after its first keyframe's period expires. A valid nonzero period shorter than the floor spins until the floor elapses. The biased timer arm precedes `agent.next()` (`session.rs:281–299`), so incoming RTP/keyframes/disconnect processing cannot cure this while it spins.

Smallest fix: make the timer transition consume the wake without automatically recreating an immediate deadline. A floor-blocked pending request must schedule the future floor boundary; a PLI-ineligible line must contribute no armed timer. Record Period only when the period itself matured, not whenever any held-cause wake matured. Add paused-clock **session** coverage for no-PLI and period < floor that demonstrates agent progress, not just `take_deadline` called twice in isolation.

### R2 — P1: held causes are not scheduled at the floor boundary

`keyframe.rs:106–111,162–183`: after a successful send at t=0, trial policy arms t=2s. Loss/step/join noted at t=0.3s leaves that deadline intact. With no further events, the held request goes at t=2s instead of the required t=1s. The existing test manually calls `poll_send` at t=1s, bypassing the broken scheduling. Regular RTP or REMB can mask this error; they are not the contract's clock.

Smallest fix alongside R1: distinguish period eligibility from pending-send eligibility; expose the earliest valid future deadline, bounded by `last_sent + floor`, and coalesce causes into that send. Keep one bounded held request. Test no subsequent RTP/REMB, overlapping causes between two sends, exact cause tags, cancellation by a keyframe, refused writer parking, and future rearm. `rearm()` currently has no production caller.

### R3 — P1: join ratio has the wrong units, and demand has no wake path

`keyframe.rs:227` requires `wanted - largest >= policy.ratio`. At the pin, ratio 4 is a **payload-byte ratio**, already evaluated by `moq-net/src/model/track.rs:1190–1214`. `Demand::wanted()` then asks for the **next free group**, typically largest + 1 (`track.rs:5906–5913`, `track/demand.rs:98–127`). This implementation rejects the ordinary eligible join at ratio 4. It needs `wanted > largest`, with the specified empty-track and initial-observation exclusions, not a second group-distance threshold.

Further, `observe_joins` only runs after `fire_gates` (`session.rs:478–499`); it never polls `Demand::poll_wanted_changed` or registers its wake. Without REMB, a join can wait until the next period and then be serviced only after a period PLI has already gone out. A parked line may never sample it. `JoinWatch` also forgets the value of its first reading: the same initial high demand triggers on the next identical sample (the current unit test explicitly blesses that behavior).

Smallest fix: consume real demand changes with an initialized baseline, coalesce eligible changes before flushing, retain the per-MID association and honor `on_join`. Test an actual track with one keyframe plus deltas exceeding 4× its bytes, subscribe, observe wanted = largest + 1 and exactly one Join send. Cover under-ratio, initial reading, repeated unchanged demand, empty group 0, rendition changes and demand while the timer is parked. Do not infer this from fabricated wanted=8 inputs.

### R4 — P2: the required pre-RTP period/park path is unreachable

`session.rs:431–434` installs `Gate::new(pli)` with no deadline, pending cause or initial period base. No period timer exists until a keyframe arrives or a PLI succeeds. Thus the specified enabled line whose period expires before its first RTP cannot enter the held/parked state at all. Startup is still driven only by `IngestOrder::admit` on a delta. Refused requests can also be retried on unrelated REMB wakes because `fire_gates` flushes every gate, including those with no due deadline.

Smallest fix: initialize the enabled video line's period deadline when opening it, then park a failed attempt until an actual receive-stream transition or an explicitly future cause. Exercise 10 seconds of silence, no receiver, missing/refusing writer, first-delta release and first-keyframe cancellation through the session. Do not implement this only in an unused helper.

## Loss trigger: distinguish an unexercised condition from a bug

The current condition at `session.rs:547–550` matches the contract: a delivered non-keyframe video `MediaData` with `contiguous == false` notes Loss **before** pinned admission decides forwarding. Usable deltas still reach the sink; keyless/too-old deltas are still dropped. `on_loss=false` excludes the added cause. I found no inversion or missing call in that branch. R1/R2 can still break its scheduling once it is exercised.

Resolved dependency is registry `str0m 0.25.0`, not an inferred latest release. Its `src/media/event.rs:253–259` defines continuity at the emitted-frame boundary. `src/packet/buffer_rx.rs:382–424` waits for retransmissions/hold-back, then combines codec continuity with expiration; at `446–455` it can suppress frames altogether. `src/packet/contiguity.rs:44–116` permits a layer-0 frame with a skipped TL0 picture ID to be emitted with false continuity, while dependent higher layers can be suppressed. A sequence gap is therefore neither guaranteed to become a delivered delta nor guaranteed to survive retransmission. A post-gap keyframe intentionally adds no Loss cause.

D2's 390 proxy packet drops, 17 period log entries, zero loss entries and an 8ms reader gap do **not** prove the branch is dead. They also do not prove the publisher blackout recovered within 1.2s: buffered/retransmitted media and a periodic keyframe can explain those observations. The committed evidence does not capture which explanation occurred.

Exact next experiment:

1. First use a deterministic str0m sender/receiver fixture with a known initial keyframe. Drop a known base-layer delta's complete RTP sequence range, including retransmissions of that range, then deliver a complete later non-keyframe base-layer frame (advance TL0 ID if present). Keep enough subsequent complete frames or advance the configured reordering deadline to release the buffer. Assert an actual emitted `MediaData { contiguous: false, is_keyframe: false }` reaches this session. A synthetic `MediaData` injection alone tests the branch, not str0m's loss semantics.
2. Keep period outside this diagnostic window, suppress unrelated joins, and wait past the floor before loss. Log MID/RID, sequence range, media timestamp, network and handling times, codec-extra keyframe/layer/picture IDs and continuity at ingest; log gate cause/result and publisher RTCP PLI. Assert exactly one accepted Loss PLI and unchanged delta admission. Repeat loss-off as the negative control. Then deliberately place loss inside the floor to validate R2's fix.
3. Re-run **trial 2s** D2 with the real 1.5s publisher-leg blackout at varied phase. Record proxy burst start/end and dropped RTP/RTX identities, and timestamp the first post-burst **keyframe**, linked to its frame counter/media timestamp at the reader. Require a Loss send and ≤1.2s from burst end. Diagnostic long-period success does not replace this adoption row. If only a keyframe emerges, report that condition and adjust the impairment to exercise the required delta; do not relabel Period as Loss.

## Other implementation checks

- Gate state is session-local and indexed by MID; no global source lookup, viewer cause, requester API, pairing table or WHEP source override was added. Harness WHEP still connects to the relay using the viewer's token (`harness/rust/src/bin/edge.rs:110–119,149–150`). Egress feedback remains logged/dropped (`session.rs:370–374`).
- Writer acceptance alone advances `last_sent`; missing writer and str0m refusals are nonfatal. `Agent::rtc_mut()` retains its drop/drain behavior, so accepted feedback is drained through the pinned driver. This is API acceptance, not proof that the encoder received/responded to the packet.
- Keyframes clear pending causes and period bases use the later of last keyframe and last accepted send. Gate arithmetic uses monotonic instants. Source ownership remains bounded by the negotiated lines, and finish/drop removes session gate state. No new reset/global identity leak found. RID is not retained for timer sends (`flush_gate(..., None)`); simulcast is explicitly outside this campaign, so this review does not claim RID-layer support.
- Unsupported ingest codecs still fail in `IngestSink::on_track` before a gate is inserted. The no-PLI guard prevents a send but **not** the spin in R1. Disabled policy retains the original `MediaData` branch and forwarding code; the 99 baseline tests alone do not establish the newly required disabled-session scenario.

## Provenance and verification

Independent K2 checker run passed: patch reverses and source/licences match the locally verified upstream checkout HEAD `4a6f522483168ace392718d68b58a402533c897d`. The patch is confined to ingest policy/session/codec plumbing and notices; no egress implementation delta. MIT/Apache texts and outbound licence are retained. Vendor drop instructions preserve the ingest-only scope.

All five K0 hashes match `harness/logs/relay-baseline.txt`; `git diff b39bf1b2 -- native/mjolnir_relay/` is empty. Offline locked harness metadata resolves one path `moq-webrtc`, one pinned `moq-net 0.3.10`, and `str0m 0.25.0`. No full duplicate consumer build was needed for these checks.

Checker hardening still owed before treating K2 as an enduring guard: `scripts/check-vendored-moq-webrtc.sh:14–33` trusts an override/cached directory without checking its HEAD; the manifest checks accept extra dependencies and unspecified feature/default-feature changes on several git dependencies (`91–116`). Reverse a future multi-patch series in reverse order, not forward order. These are checker weaknesses, not evidence that today's checked tree has a different pin or licence. K5's durable relay-after record, P9 clippy evidence and U1–U4 remain unfinished in tasks.

Focused local Rust reproduction, using the production gate text with only the clock import adapted to `std::time::Instant` and checked addition for these finite test intervals, reproduced four faults: held loss at 300ms still scheduled at 2000ms; 100 consecutive due polls at a fixed 100ms when period < floor; 100 due polls without PLI; and next-group join demand ignored at ratio 4. This is a gate/scheduler-transition reproduction, not a full session timing test. See the companion reproduction script.

The reported 110 tests consist of 99 upstream tests plus 11 new gate/helper tests. New tests do not drive the modified session loss path, actual join demand, writer refusal/receive transition, startup/step coalescing, viewer PLI, public accept validation or timer select loop. The paused-clock helper test compares instants without advancing a session. Passing 110 is useful regression evidence, **not P1–P8/H2 completion and not empirical adoption**.

Independent full-suite attempt: Framework checkout HEAD was `4616f669`; the gate and session SHA-256 matched this review's tree exactly (`e76db8b116354ed0f56a92cbbed394668c8a2552708ceb23303cd2654091bdd5`, `fbf83897725fe143da47b3bd01b852258705f38225136f14b43c6b03244b8c40`). Ran `CARGO_TARGET_DIR=/tmp/kf-after cargo test --locked --manifest-path native/vendor/moq-webrtc/Cargo.toml`. Cargo unexpectedly rebuilt dependencies with its default profile, reached compilation of moq-webrtc, then the host became unreachable before any test result arrived. **No independent 110-pass claim from this run.** No remote source files or other agents' caches were deleted. Parent should check the outstanding command before starting another build. The Mac had only 7.1GiB available; no duplicate Cargo build was started there.

## Measurement gates still owed

- **A:** the 10 H.264 and 10 VP8 after samples are real WHEP pictures, but `after-720.sh:29–60` uses ffmpeg → native `harness publish` → relay, bypassing WHIP and its gate. Repeat before/after with WHIP-origin media, same route/cap/fixture and varied phase; prove the period caused the requested keyframes.
- **B:** one 43ms/0.733s-lag sample is not ten joins; the scripted source is native MoQ here too. Need ten WHIP-origin decodable joins, lag against simultaneous probe, and first/reopened upstream versus later relay-local join traces with negotiated wire version.
- **C:** only capped native-MoQ VP8 exporter evidence; uncapped WHIP VP8, VP9 and AV1 remain unrun. Record content results and required `.13` follow-up if failing. C is record-only, not an invented adoption gate.
- **D1:** dropped viewer packets recorded, but no post-burst presented counter established. Finish the observation; 1.2s is not its pass gate.
- **D2:** failed/unexercised as above. Period PLIs are not loss evidence.
- **E/D3:** zero viewer-cause lines is structurally expected because the enum has no Viewer. Zero peer-PLI lines and native-MoQ source do not prove an exercised storm. Use one then four actual PLI-generating viewers for 20s against a WHIP source through the viewer-authorized relay path; capture received feedback plus unchanged ingest causes. Use the supplied PLI viewer or another observable sender, not a zero-match grep alone.
- **F:** WHIP shares 0.0034/0.0385/0.0937 are partial observations. `period=1s` is not a continuously eligible ingest-cause saturation hook: each responding keyframe resets it. Need the named eligible-cause hook, matched off/trial/saturation runs, byte totals and duration/bitrate delta; quality may explicitly remain missing under D6. Do not compare native-MoQ baseline share 0.1814 with WHIP after share as a policy cost delta. F-PR still owed.
- **H0/H2:** `probe_selftest` prints a counter initialized to zero and never incremented (`harness.rs:498,530`), on tracks without a gate. It does not establish zero observer-induced join PLIs. Opening only after a group exists can itself trigger refresh if its deltas exceed the ratio. Exercise the real probe and rendition change with the active demand/gate and capture causes. H2 has no committed per-cause session self-test log.

Keep adoption unchecked. The smallest implementation repair is R1/R2's scheduler transition, R3's real demand wiring, R4's initialization/parking, plus focused integration regressions and regenerated reversible patch. Measurements and local upstream preparation remain separate work after code acceptance.
