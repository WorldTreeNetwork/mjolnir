# Independent code re-review — ba1e99f8

**Code: SEND-BACK, narrowly. Adoption: NOT READY.**

Reviewed exact code `ba1e99f8a80127e557de34835abd468191c35d46` against `b33ddf24527039a2c2af7e47d1c5c4a1055622a2`, and the prior sendback at `55b481a72c333f3da7e00ad4d9329bdfaba84083`. The prior review file is unchanged (SHA-256 `c12f9d7e38a19124b2802476f91c1a7320b5a9a8c200c0956e28841104d44872`). No architecture reopening, product edits, deployment, remote build, or media/adoption claim. `.12` remains open; no `.13`/`.15` unblocking.

## Remaining code findings and smallest fixes

### R5 — P1: the first eligible join can be swallowed by the asynchronous baseline

`session.rs:453–475,529–543`: the task correctly polls real `Demand`, but discards its returned value and sends only `()`. `JoinWatch` is still uninitialized until the session handles a notification and re-reads the sink. A legal ordering is: open line; watcher reads `None` and queues notification; write a group exceeding the byte ratio and subscribe; watcher queues another notification; session handles both. Both now sample the same high wanted value. The first establishes the wrong baseline and the second is unchanged, so neither requests Join. No later change is guaranteed before the period.

Independently reproduced with a real ratio-4 moq-net track and the actual spawned watcher and `Session::run_loop`: two notifications queued, wanted = largest + 1, zero Join writer attempts. A control that lets the session read the baseline before subscribing does attempt Join. This is not a group-distance arithmetic failure; that part was repaired.

Smallest fix: establish each MID's baseline synchronously when its demand is attached, before spawning/yielding, and preserve change ordering (or use a coalesced notification against that established baseline). Process eligible joins before flushing simultaneous due timers: currently the biased timer arm at `session.rs:295–310` still precedes demand at `312–316`, so an already-queued join can miss the same send and wait another floor. Add deterministic tests for delayed first notification, join before first watcher poll, simultaneous period/floor plus join, no REMB, parked timer, unchanged demand, under-ratio, and track/rendition replacement. Do not merely change the helper's fabricated inputs.

### R6 — P2: a join bypasses parked-writer suppression

`keyframe.rs:130–143,225–247`; `session.rs:539–560`: `note()` correctly leaves an immediate cause parked, but `observe_joins()` unconditionally calls `flush_gate()`. Both `ready()` and `poll_send()` ignore `parked`. Thus a fresh eligible Join touches the writer again without an arriving media event or a strictly future rearm. If the writer is still missing, `held` increases again; if it became available, an otherwise prohibited immediate retry can succeed. Success also fails to clear the stale parked flag.

Independently reproduced through `run_loop` with a negotiated video line, an explicit missing-writer fixture, and real demand: first attempt parks with `held=1` and no deadline; an eligible Join, without media or a future deadline, produces `held=2`. Unrelated `fire_gates()` calls alone stay quiet, so the REMB-only retry defect is repaired.

Smallest fix: make parked state part of the send predicate, including direct `poll_send`, and clear it explicitly on permitted rearm/accepted send. Preserve `on_receiver` before keyframe cancellation, so a first keyframe cancels rather than releases the request. Add session tests for a join while parked, refused/missing writer, delta release, keyframe cancellation, and strictly future rearm. The existing `silence_parks_a_missing_writer_until_media` test explicitly expects a direct retry while parked and therefore blesses this hole.

### R7 — P2: demand task lifetime is not bound to the session

`session.rs:458–475`: the `JoinHandle` is discarded and the task awaits only demand. Dropping the channel receiver does not wake that demand future; `tx.send` notices closure only after another track event. With a public custom `MediaSink` and an externally retained idle producer, dropping Session leaves the task and its sender alive indefinitely. Reproduced by retaining a weak sender: it still upgrades after Session drop and stops upgrading only after aborting the track.

The concrete `IngestSink::drop` aborts its bridges, and Demand is weak, so normal WHIP teardown wakes this task and it does not pin cached groups. This finding is specifically the public Session/custom-sink cancellation path, not a claimed normal-WHIP media leak.

Smallest fix: select demand polling against `tx.closed()` (or retain an abort-on-drop task owner). Verify cancellation with a live external producer and no subsequent demand changes. Keep the current persistent `kio::Waiter`: its waker belongs to this one Tokio task, so select cancellation in the parent does not invalidate it; the pin's locked check/register and weak waiter registrations are appropriate here.

## What is repaired

- R1: due timer transitions consume their deadline. A short period marks Period once, then arms the future floor as `Wake::Send`; no-PLI lines arm no timer at opening or on keyframe. Actual run-loop timeout/progress fixtures pass for short period and no PLI. These fixtures demonstrate loop progress, not successful RTP delivery.
- R2: accepted send at t=0, Loss at t=300ms, no later media/REMB: actual paused-clock loop attempts at t=1000ms rather than t=2000ms. The held cause is exactly Loss, not Period. Earlier deadlines remain earliest; keyframes clear pending causes and restart the period from the later of keyframe/accepted-send time.
- R3 arithmetic: byte ratio stays in pinned moq-net; `wanted > largest` is correct after it requests the next group. The real-track over/under-ratio tests are useful. Initial unchanged high samples, empty tracks and `on_join=false` are excluded by the helper. The asynchronous baseline race above prevents full R3 acceptance.
- R4 opening: `Gate::open` is reached by real video opening. A paused-clock actual-loop fixture lets ten seconds elapse with no media and missing writer: one held attempt, then no timer; 100 subsequent `fire_gates()` calls do not retry. The join bypass above prevents full parking acceptance.
- Loss predicate and forwarding remain unchanged: delivered discontinuous non-keyframe media notes Loss before pinned admission; no empirical str0m loss-condition/adoption proof is inferred. The new `loss-watch` harness mode only makes a 30-second diagnostic period available; it is not a successful experiment and not F's saturation hook.

## Independent verification and limits

Local macOS, low-debug cached target `/tmp/kf-gate`, two jobs:

```sh
CARGO_TARGET_DIR=/tmp/kf-gate CARGO_PROFILE_TEST_DEBUG=0 CARGO_PROFILE_DEV_DEBUG=0 CARGO_BUILD_JOBS=2 cargo test --locked --offline --lib --manifest-path native/vendor/moq-webrtc/Cargo.toml
```

**115 passed, 0 failed**, independently rerun against the unmodified reviewed source. This is 99 upstream tests plus 16 helper/gate tests. No new production-session regression module was added by the builder. The biased-select helper uses an already-ready channel and a no-PLI gate; it does not negotiate media or execute `Session::run_loop`. Passing this suite does not complete P1–P8/H2.

Companion `reproduce-ba1e99f8.py` extracts this exact commit into disposable source, appends `reproduce-ba1e99f8.rs` inside the session module, and runs only six independent reproductions: **6 passed, 0 failed**. Three assert corrected scheduling transitions; three assert the remaining observed bugs. They use actual session functions, the actual demand task/channel, real pinned moq-net tracks, and local ephemeral UDP sockets. The fixture opens an SDP-negotiated line, then replaces its Agent with an empty RTC to make a missing writer deterministic; the short-period/loss fixtures seed the previous successful send directly. They do not claim a browser, RTCP delivery, encoder response, str0m loss emission or media recovery. No source adaptation to `std::Instant` was needed. Initial fixture compile/assertion mistakes were corrected before the reported final six-test run.

K2 checker passes using the local Cargo checkout, whose HEAD independently equals `4a6f522483168ace392718d68b58a402533c897d`. Patch reversal reproduces source and licence texts. Five K0 hashes match; relay diff against `b39bf1b2` is empty. Locked offline harness metadata resolves one path moq-webrtc 0.3.12, one moq-net 0.3.10 at the pin, and registry str0m 0.25.0. No dependency/egress implementation drift found.

Checker limitations from the prior review remain. Additionally, a local override without the required source layout reached the fresh-fetch fallback, which failed at `git sparse-checkout set ... LICENSE-MIT LICENSE-APACHE` because cone mode treats those file arguments as directories. The successful cached-checkout check proves this tree's provenance, not that the clean fallback works. Fix fallback file selection alongside exact HEAD/manifest checking; reverse a future patch series in reverse order. No checker/product files were edited here.

Framework remains unavailable by the supplied context. No remote connection or duplicate build was started. The prior outstanding job's result remains unknown; the builder log's assertion that it “died with the host” is not independent evidence of termination. Check that job before starting a replacement when the host returns. P9 clippy and durable K5 record remain owed; no new claim for them.

## Measurements and handoff still owed

- A/B: current after scripts bypass WHIP through native MoQ publishing. Repeat matched WHIP-origin off/trial media, ten H.264 and ten VP8 joins for A, ten decodable MoQ joins for B with simultaneous probe lag and first/reopened versus later relay-local subscription traces plus negotiated wire version.
- D2: actual delivered non-keyframe `contiguous=false` must exercise Loss, then real 1.5-second publisher blackout at trial period 2s must yield a traced Loss PLI and first post-burst keyframe within 1.2s. Keep the prior review's deterministic RTP/RTX suppression experiment; 390 drops, period-only PLIs and an 8ms gap remain insufficient.
- E/D3: one then four actual PLI-generating viewers for 20 seconds, with observed peer feedback and unchanged ingest causes over the viewer-authorized relay route. Zero Viewer-enum matches is not an exercised control.
- F/F-PR: named continuously eligible ingest-cause hook, matched off/trial/saturation runs, bytes, durations and bitrate delta; explicitly report missing quality. `period=1s` is still reset by keyframes and is not saturation. Do not compare native-MoQ off with WHIP trial as cost evidence.
- C uncapped codec rows, D1 presented post-burst counter, real H0 probe/rendition cause observation and H2 per-cause session log remain owed. H0's synthetic zero counter does not complete its observer assertion; its box is reopened precisely for that evidence.

Fix R5–R7, add the meaningful session regressions, regenerate the reversible patch, then obtain a fresh code review. Measurement/adoption work and local upstream preparation remain separate and unfinished. No change to the accepted ingest-only architecture or relay authorization.
