# Independent narrow CODE re-review — 4bd94d1d

**Verdict: ACCEPT** for exact product `4bd94d1d5187f7d293eea72a3852ef3e36222fc5`. Remaining V1/N2 is resolved at the code boundary. N1/N3/N4/N5 stay accepted; no regression was found. The earlier apparent missing-source 503 is explained by malformed SDP, not an outstanding R6 mapping defect.

Read root/OpenSpec AGENTS, `bd prime`, `.13` history, prior 9356fa2 review/reproduction, original R6 finding, contract/tasks, changed code and relevant pinned vendor paths. No agents, product/vendor changes, deployments, closure or fold. New probe files are separate from immutable historical scripts. HEAD advanced to builder evidence commit `4aca24a9` during review; its product/vendor files remain identical to the exact reviewed hash.

## V1 / remaining N2 — resolved

`native/mjolnir_relay/src/edge_http.rs:296–308` now registers/checks pending cancellation before delegating vectored output, using the same guard as scalar writes. A pending invalidation wakes the HTTP task and causes `ConnectionAborted` even while the underlying vectored write remains Pending. The successful-underlying-flush acknowledgement boundary is unchanged. Settled tickets remain removed; later HTTP cancellation cannot remove acknowledged incumbents through this context.

Independent `real_held_output_terminates_on_all_invalidations` ran all twelve combinations: held scalar writes, held final flushes and held vectored writes, each invalidated by deadline, DELETE, drain or same-token relay connection close. Every fixture uses an ephemeral TLS MoQ relay, real WHIP `Some(Response)`, an acknowledged same-token incumbent and a different-token control. The vectored double advertises support and captures its waker only on entering `poll_write_vectored`. The test waits for that entry before invalidation, so this is actual production Hyper vectored output, not merely a capability flag or candidate insertion assertion.

All HTTP tasks completed with errors without external task abortion, releasing the socket or explicitly waking its captured waker. Vendor registrations were gone afterward. Deadline/DELETE preserved both incumbents (`refs=1,1; runners=2`); same-token relay close removed that generation and preserved the other token (`0,1; runners=1`); drain removed all (`0,0; runners=0`). The deadline uses the original real five-second setup budget. This is deterministic controlled backpressure, not a claim to fill a kernel TCP buffer. Cleanup aborts the fixture relay only after assertions.

The parent's checked-in regression uses a test dial and enables vectored support for DELETE. The independent real-Response matrix above supplies the broader runtime evidence. Existing scalar/flush behavior, TCP successful delivery, natural runner completion, transport failures and pipelining also passed. EOF still marks serialization only; acknowledgement follows successful underlying flush, not remote peer receipt or browser application.

## R6 diagnostic correction — no remaining finding

Read `reviews/2026-11-27-4bd94d1d-evidence.md` committed in `4aca24a9`. The earlier 9356fa2 missing-source request actually posted `v=0`. Vendor `server/whep.rs:155–165` parses SDP **before** resolving the broadcast. InvalidSdp becomes `SetupFault::Other` through `moq_session.rs:99–107`, then `503 setup_failed` through Edge classification. The URL alone does not establish that catalog lookup ran. Expiry still takes precedence.

The builder's corrected same-token comparison uses a real Chromium offer and gets `409 not_started` at missing/cam. Independently, this review exercised production HTTP with a valid generated audio/video receive offer and got 409, preserving both incumbent runners and refs. A separate actual-relay probe announced `alice/no-catalog` without a catalog: direct negotiation returned typed `Catalog`, and HTTP returned 409. The strengthened HTTP comparison additionally checks the same valid token and same missing path with malformed `v=0` (503) versus the valid offer (409).

Therefore the supplied 503 is not evidence of a remaining missing-source mapping defect. No mapping repair is requested. Potential nested vendor error shapes were inspected but no failing contract case was established; they are not promoted to speculative blockers. The prior real catalog-timeout/controlled-expiry regression also passed. These generated-offer probes are local protocol evidence; the builder's Chromium offer and real Mint playback remain separately attributed.

## Tests actually run

Local macOS, Rust 1.95.0, offline existing cache, `CARGO_BUILD_JOBS=1`, `CARGO_INCREMENTAL=0`. New `reproduce-4bd94d1d.py` extracts exact committed product/vendor files into a disposable directory, then appends its separate review module and offer-generation dev dependencies. Product files in the working checkout were not modified.

1. First attempt failed compiling moq-webrtc with ENOSPC, exit 101, before any test ran: `reproduce-4bd94d1d-result.txt`. Space later became available; this reviewer did not clear shared caches or stashes.
2. Retry via `python3 openspec/changes/add-webrtc-edge/reviews/reproduce-4bd94d1d.py`: exact checked-in library **37 passed** (1.95 s), then independent suite **14 passed** (61.82 s). `reproduce-4bd94d1d-retry-result.txt`. Baseline command is `cargo +1.95.0 test --offline --locked --lib -- --test-threads=1`; independent command selects `edge::independent_review` with `--nocapture --test-threads=1`. This suite contains acceptance assertions, not the historical intentional V1 defect characterization.
3. Added announced-source/no-catalog probe: **1 passed** (10.40 s), `4bd94d1d-catalog-result.txt`. Command adds `MJ_REVIEW_SKIP_BASELINE=1` and filter `real_announced_source_without_catalog_mapping` to the script invocation.
4. Strengthened malformed-versus-valid HTTP comparison: **1 passed**, `4bd94d1d-offer-comparison-result.txt`. Same skip-baseline invocation with filter `real_missing_source_http_contract`. This is a rerun of the changed comparison, not an additional unique test in the earlier 14 count. The saved module contains the strengthened comparison and extra catalog test (15 unique review tests total).

Python syntax and `git diff --check` passed. No separate TLS test target, remote build or browser playback was rerun by this reviewer. The parent’s focused/37 results are not substituted for these independent results.

## Named-peer and release disposition

**Yes: this exact-hash code acceptance plus the current-hash local media evidence unlocks the already authorized named-peer `.15` implementation slice under D7.** No new authorization is required for that slice. This is not whole-node acceptance or production enable.

Builder-owned `4aca24a9` records current 4bd94d1d Arch playback with matching colors, 439 Hz tone and 166 decoded frames at **320×180**, not 720p. It also records Ubuntu 24.04 incremental source rebuild and admission smoke: only the two changed files were copied onto the prior full source build, their hashes matched, initial missing-cc PATH failure was corrected, and the new binary was distinguished from retained 9356fa2 binaries. Accept that as current incremental-build/smoke evidence, not a new clean build or this reviewer's execution. Older early/late playback retains its older-hash provenance.

`.12` whole-node dependencies, roster, Safari/eight-PC, Hang, broader owed media enforcement/cleanup and production enable retain their separately recorded gates. `.13` remains open. No `.15` implementation, node closure, fold or deployment was performed here. Existing unrelated stashes and `.beads.gate.lock` were left untouched.
