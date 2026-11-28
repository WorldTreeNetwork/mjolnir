# Independent narrow CODE/UI re-review — SEND-BACK

Exact reviewed implementation: **1385fab1adf8932970622adce271416fce9d7cd2**. Fresh assigned reader, parent Codex authored. Read AGENTS/bd, accepted a1be084f contract/advise-3, design/spec, and the 6f98d267 review recorded at 093904e6. Scope: mjolnir-rurh.15; no product edits, nested agents, deployment, closure or fold.

## Independent results

- `npm test --prefix native/mjolnir_room`: **44/44 pass**.
- Adjacent `2026-11-27-rereview-1385fab1-probes.mjs`: first **13 positive adapted probes: 12 pass / 1 fail**. The six historical defect assertions now assert repaired behavior. Historical files remain untouched. The DOM double now implements `.tile` selection required by the real page.
- Four additional narrow checks: **3 pass / 1 fail**. Total **15/17 pass**. These execute the actual module/page source with dependency/VM DOM doubles; no independent native browser or media run is claimed.
- Passing extra checks: a two-second admission deadline settles held SDP, stops the camera and prevents a late answer from reaching setRemoteDescription; supersession settles old SDP and preserves the newer owner; same-element playing/waiting callbacks do not overwrite an already blocked caption or hide recovery.

## P2 — New retry tracks can be retired by another peer's update

`native/mjolnir_room/page/boot.js:189`, with `src/room.js` playPeer/armPeerRetry state transitions.

The integrated probe uses the real createRoom callbacks wired into the real boot.js DOM double. Join Bob and Carol; Bob initially returns 409. Fire Bob's retry timer. Its actual PC ontrack delivers a valid new video while its answer/connection work is pending. Bob's state has the new attempt and `inflight=true`, but still carries `empty=true` from the prior 409. Disconnect Carol's real PC to cause a normal onUpdate. paint sees Bob's `empty` and clears the **new** stream. Then Bob connects successfully: state.empty becomes false, but srcObject stays null. There need not be another ontrack event, so a successful subscription is displayed empty indefinitely.

This is a concrete interleaving within the accepted multi-peer/retry contract, not a claim about the concurrent tone diagnosis. Holding setRemoteDescription models the pending negotiation interval; ontrack can precede ICE readiness, and the same stale empty state persists throughout that interval.

**Smallest repair:** distinguish a current inflight attempt that has delivered tracks from the retired/empty attempt. For example, retain matching-owner pending streams while still retiring owner mismatches and settled empty/failed results; ensure failed attempts subsequently clear those tracks. Keep the no-track generation-commit and 409 retirement checks. Add this integrated two-peer interleaving to direct regressions.

## P2 — Pending-body retirement dispatches DELETE twice

`native/mjolnir_room/src/room.js:511` discardAttempt and `:697` teardown.

The adapted positive historical probe holds a trusted 201 body with a known Location, then Leaves. The join now correctly settles. However, deleteOwned synchronously removes and deletes the session during teardown; the awakened negotiate returns its retained session object and discardAttempt unconditionally dispatches another DELETE. Observed **2 calls to the same session, expected 1**. The five new direct tests check settlement/resource release but do not assert the cleanup count.

**Smallest repair:** claim the session for deletion once (membership check plus removal in discardAttempt, or shared idempotent session cleanup). A late Location registered after Leave must still receive its one DELETE. Add exact-count checks for both header orderings and supersession. This is a bounded duplicate request/bookkeeping defect; no cross-owner deletion or credential leak is asserted.

## Accepted repairs and limits

Trusted 201 Location is registered before the immediate ownership check. Late headers after Leave settle without waiting for the held body and delete the allocation. Known-before-Leave SDP now settles on retirement. The body deadline is min(5000 ms, admission expiry minus now), clamped to zero; the two-second expiry probe confirms no expired SDP side effect. Body rejection remains covered by the passing unit suite.

Generation commit with no new tracks and the subsequent empty peer update now clear old views and obsolete recovery controls. Detached elements are invalidated and cannot update a new registered tile. Captured owner/stream plus playback revision reject stale play completions, including same-owner reordered promises. Successful playback of another tile does not hide a still-blocked tile's recovery.

Same-element media listeners read the element's **current** owner/stream at dispatch, unlike play promises which capture them. The passing blocked-event check establishes its stated behavior only. Artificially labeling a generic event as belonging to an old stream would not establish native browser event provenance; this review adds no speculative blocker from that. Neither event captions nor these doubles establish actual audible playback.

The builder's concurrent audio diagnosis is separate evidence. Full current-stream colours plus sustained expected tone after replace/renew, and the previously owed D5 existing/new subscriber failure observations, remain separate unmet acceptance gates for this review. No media acceptance, .15 closure or whole-node completion is granted. **Code verdict SEND-BACK for the two small reproducible issues above.**
