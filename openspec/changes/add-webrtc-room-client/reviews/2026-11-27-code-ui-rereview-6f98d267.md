# Independent CODE/UI re-review — SEND-BACK

Exact reviewed implementation: **6f98d267e5c3ce165cff54db00b120ac1892354e**. Read AGENTS/bd, accepted a1be084f browser contract and advise-3, and b21d28ce's prior review/19 probes. This is the assigned fresh reader; no nested agents, product edits, deployment, closure or fold. Scope remains **mjolnir-rurh.15**. Concurrent `2026-11-27-tone-diagnosis/` work belongs to the builder and was not edited or treated as completed evidence.

## Independent checks

- `npm test --prefix native/mjolnir_room`: **39/39 pass** on the exact hash.
- Unchanged `2026-11-27-rereview-72ec611-probes.mjs`: **9 pass / 10 fail**, matching the builder. Eight positive checks pass; ten old defect assertions fail; the remaining old defect assertion omits the generation argument.
- Adjacent `2026-11-27-rereview-6f98d267-probes.mjs`: **13/13 pass**, explicitly **7 repair checks and 6 bad-behavior reproductions**. Green DEFECT tests reproduce failure, not acceptance. Historical probes remain untouched. Module and VM DOM doubles, not a new real-browser run.
- Read actual `pc.ontrack` construction and independently fired old/new production PC callbacks: both use attempt 1, but generation IDs are 1 and 2; retired PC callback is ignored. Feeding these current-interface identities to the page removes old video when new audio arrives. The historical omitted-generation ambiguity is **not reachable through this production callback** and is not a finding.

## Remaining findings

### P1 — R1 remainder: late allocation headers after Leave still wait on the SDP body before cleanup

`native/mjolnir_room/src/room.js:456–479`.

Repro: hold WHIP response headers; Leave completes and releases camera/PC; deliver a trusted 201 with valid `/session/latebody`, but hold `response.text()`. The code appends that session to an already retired generation, then awaits the body without checking ownership. **Zero DELETEs and an unsettled old join** persist until the body resolves. The old generation is no longer reachable by a subsequent teardown. Resolve the body and DELETE finally occurs. This combines the real late-response path with the already-reviewed body failure path; no malformed dependency is needed. A streaming HTTP response can deliver headers without finishing its body.

When headers arrive before Leave, registering Location first now correctly permits immediate DELETE. However, the join itself still does not settle on Leave while its body hangs (separate passing defect probe). Before commit there is also no generation expiry timer to release a camera held by that body wait.

**Smallest fix:** after trusting headers and registering a valid allocation, check ownership immediately and discard a stale attempt without consuming SDP. Race body consumption against owned cancellation and a finite admission/deadline bound; ensure cleanup runs once, including late responses. Test both header orderings, supersession, body rejection, and expiry with a body that never resolves. Preserve the existing late-allocation DELETE behavior.

### P2 — R3 remainder: remote view retirement is still driven by the next track, and detached callbacks can write into a new tile

`native/mjolnir_room/page/boot.js:45–67,108–135,147–170,207–212`.

Generation+attempt identity works **when a new track arrives**. It is not reconciled when the incumbent changes. Repro: generation 1 receives video, then generation 2 commits with no peer tracks yet and receives `409 not_started`. `paint()` retains the old `srcObject`; if the old tile was blocked, its obsolete Play media control also survives. Production sends this sequence: it notifies after commit before starting the new peer attempts. With no successful new subscription, the retired stream can stay attached indefinitely rather than the tile becoming empty. This is not the obsolete missing-generation probe.

On Leave/expiry, `replaceChildren()` detaches tiles but does not invalidate their owner tokens, clear their streams, or guard event handlers. Repro: hold an old tile's play promise, Leave, Join, make the new tile's play reject, then resolve the old promise. Its guard compares against the **detached old element**, succeeds, and `setCaption(path, ...)` writes **Playing** into the new blocked tile. Independently dispatching the detached old element's `playing` handler also overwrites the new caption. Media event handlers have no ownership guard at all. No generation-less production callback is required.

**Smallest fix:** reconcile remote views against live generation and peer attempt/state at commit and retry, before any new track; explicitly detach/invalidate retired streams. Guard play completions and media events against the currently registered tile, stream and owner, including after removal. Recompute recovery visibility after retirement and settled playback. Test no-track/409 replacement, Leave/new-Join with late play settlement, and retired-element events. Keep video/audio of the same current subscription combined.

An additional dependency-boundary probe shows same-owner play completion reordering can hide a newer rejection: video and audio callbacks both call `play()` with the same owner. This is **not independently demonstrated as native Chromium promise ordering** and is not a separate blocker. A playback request revision would address this alongside the confirmed retirement problem; do not cite the double as the cause of real silent audio.

## Repairs accepted within their tested bounds

R1 PC constructor and MediaStream constructor failure now release the candidate; body rejection with known Location deletes it. R2 gather and connect waits explicitly settle on retirement even when `close()` emits no event. R4 expiry clears tiles/status, and action identity prevents old Leave completion overwriting newer Join. R5 implements gateway single UTF-8 decode/canonical paths: escaped ASCII, Unicode, leading-dot names, forbidden escapes and byte-boundary checks pass against the inspected gateway grammar. R6 refcounts preserve shared tracks across failed replacement, successful commit, superseded delayed camera and final release. R7 consistently rejects redirected/foreign responses for admission/media/DELETE; native requests retain `redirect:error`. No credential-leak claim is made.

R3 now rejects stale play completions after owner changes on the same element, combines one audio and one video track per current owner, and keeps recovery visible when another current tile remains blocked. The missing-generation historical assertion is obsolete. These are meaningful repairs, but do not cover view retirement above.

## Media evidence is a separate unmet acceptance gate

Read `2026-11-27-code-ui-rerepair/OUTCOMES.md` and its driver. This is builder-run accepted-gateway evidence, not independent browser execution by this reader. Initial receive: 640×360 expected colors, ~439 Hz/rms 0.0095. Replace and valid renew: expected 640×360 colors, **0 Hz/rms 0**. Later forced-autoplay recovery click: ~439 Hz and hidden recovery button. The record also supplies real-page hooks for constructor throw, SDP body rejection/DELETE 204, held gathering/Leave, failed shared-camera replacement, hung DELETE/newer Join, and expiry.

Neither screenshots, `Playing`, connected ICE, nor a live audio track establishes restored sound. The driver analyzes the first audio track of the page's combined stream via a fresh AudioContext, with two samples when the first peak is zero. The page does not set remote `muted`; it retains the other-kind track when adding audio/video in the same owner. There is no source proof here that refcounts or combining caused the zero samples, nor proof that they are harmless. MediaStreamTrack mute state is not assessed by the UI's playing caption. The shown code can therefore say Playing while video advances and audio is silent. Do not turn that into a speculative audio transport fix.

**Still owed on .15:** measure post-replace and post-renew colors **and** sustained nonzero expected tone on the current subscriber stream; correlate audio track IDs/muted/ended state, RTP audio progress and AudioContext state to distinguish receiver mute/transport from measurement or autoplay. Record whether recovery needs user action and whether the UI offers it. The builder's concurrent diagnosis may resolve this, but this review does not prejudge it. Accepted non-atomic selection is not a waiver for permanent mute. D5 existing/new-subscriber same-path answer failure, remote-description failure and ICE-timeout observations remain owed separately.

Provisional source/VM status-and-recovery UX score: **7/10**, using UX Heuristics. Remaining major issue is stale playback/status ownership; full A/V evidence is incomplete. This is not rendered-browser, keyboard, responsive or accessibility certification. No unrelated redesign gate is introduced. `.14`, Safari phone, three networks and eight PCs at 720p remain separate whole-node gates. **Code verdict SEND-BACK; full A/V recovery unproven; keep .15 open.**
