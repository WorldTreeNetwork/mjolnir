# Independent CODE/UI re-review — SEND-BACK

Reviewed exact implementation **72ec6110abc8483bbf64bb535e9e5a1e5cb972e4**, accepted a1be084f design/spec and advise-3, prior code/UI review committed at 0911c966, and its unchanged 15 reproductions. Read AGENTS and bd workflow; scope tracked on **mjolnir-rurh.15**, which remains open. No agents, product edits, deployment, closure or fold. UX Heuristics used for status/recovery review; no rendered-browser or accessibility certification performed by this reader.

## Independent evidence

- `npm test --prefix native/mjolnir_room`: **27/27 pass**.
- Historical `2026-11-27-code-repros.mjs`: **15/15 fail**, as expected for assertions of old bad behavior, but not sufficient proof. R1–R11 and R15 fail on changed behavior (redirect refused, no expired camera/POST, immutable peers, prompt release, caught offer failure, DELETE after SDP failure, immediate supersession close, one retry, closed failed PC, path rejection, WHIP 200 refusal). **R12 fails only on case-sensitive `/waiting/` versus `Waiting`; R13 calls removed `deps.ontrack`; R14 lacks `replaceChildren` in its DOM double.** Those three do not exercise the claimed fix.
- New adjacent `2026-11-27-rereview-72ec611-probes.mjs`: **19/19 assertions pass: 8 positive repair checks and 11 remaining-defect reproductions**. Names explicitly distinguish PASS from DEFECT; a green defect reproduction is not acceptance. Adapted the historical/current harnesses without modifying history. These are deterministic module and VM DOM doubles, not gateway/media evidence.
- Positive checks independently cover two-second cleanup timeout/abort with immediate local release; incumbent retry during a pending candidate that fails; cancellation of a pending retry on leave; delayed camera ownership; admission response redirect rejection; current-attempt track replacement and autoplay failure; late successful allocation after leave; setLocalDescription failure; and candidate ICE timeout preserving incumbent. The combined retry/delayed-stream scenarios count as individual test cases in the total above.

## Remaining findings and smallest fixes

### P1 — R1: Candidate lifecycle still has exception and response-body cleanup holes

`native/mjolnir_room/src/room.js:348–352, 394–410, 556–560`.

The PC and MediaStream constructors are outside `negotiate`'s try; `begin` has no encompassing lifecycle catch. A throwing PC constructor makes join reject with the candidate still registered and its camera track still live. Existing createOffer/setLocalDescription/setRemoteDescription repairs do work.

A 201's validated Location is read **after** awaiting `response.text()`. With `/session/allocated` and a body-read rejection, join returns setup_failed and local resources close, but **zero DELETEs** occur. With a pending body, Leave closes local resources promptly but cannot DELETE the already allocated session; only resolving the body later discovers and deletes it. The current test covers SDP application failure, not body reading failure.

**Smallest repair:** wrap the complete post-camera candidate lifecycle (including constructors) in exception-safe cleanup; immediately validate and register the session from successful response headers before consuming SDP. Preserve cleanup metadata through every failure. Make body work cancellable/bounded by generation ownership/deadline. Keep cleanup idempotent and preserve the incumbent.

### P2 — R2: Retiring a generation clears the timer that was supposed to settle its wait

`room.js:247–277, 324–339, 371–381`.

Probe leaves while ICE gathering is pending. Retirement clears its 1500ms timer; the wrapper also refuses to invoke it after retirement. The ICE listener resolves only for `complete`, so the old join **never settles**, although local tracks and PC are closed. Supersession has the same path. Readiness waits similarly rely on a closed-state event rather than an explicit cancellation settlement; the normal fake PC's synchronous close event masks that dependency.

**Smallest repair:** generation-owned cancellation callbacks must settle gathering/readiness waits, remove listeners, and clear their timers. Retiring should return stale for old work without waiting for a browser event. Test close without fabricated event emission. The ordinary scheduled peer retry is correctly cancelled; this finding is about an already-running wait.

### P2 — R3: Remote views and playback completions are not owned by a generation

`room.js:361–365, 479–480`; `page/boot.js:108–129, 197–204`.

The module correctly rejects callbacks from a retired generation, but passes only a **per-generation attempt counter** to the page. That counter restarts at 1. Old generation attempt 1 video plus new generation attempt 1 audio therefore share the same stream until the new video arrives; the probe retains `old-video` alongside `new-audio`. If the next peer never supplies media, the old tile remains attached. Same-attempt same-kind replacement and different-number retry replacement are repaired.

`play().then/catch` has no ownership guard. Resolve an old pending play after a new attempt rejects autoplay: it overwrites the new blocked caption with **Playing** and hides **Play media**. A successful play on one tile also hides the global recovery control even if another tile is still blocked. The recovery click checks blocked state before its asynchronous results settle.

**Smallest repair:** use a `(generation, peer attempt)` identity or globally unique attempt ID, clear/replace remote views when ownership changes, and guard play completions and media events against that identity/current stream. Compute the global recovery control from all current tiles after each completion. Do not infer decoded video from ICE or an audio-only play.

### P2 — R4: Expiry and old Leave completion still render false call status

`boot.js:135–150, 188–195`.

With successful join then an expiry-shaped module update (`incumbent=null`, peers empty, local cleared), the page retains **In the room** and the peer tile. `paint` iterates only present peers and never reconciles global lifecycle or removed views. Separately, hold teardown cleanup, join again successfully, then resolve the earlier Leave: it overwrites the newer **In the room** with **Left the room**. Join/replace/renew use action IDs; Leave does not check one after awaiting cleanup.

**Smallest repair:** reconcile expiry/no-incumbent transitions and remove orphaned peer views, exposing an expiry reason if needed. Give Leave the same captured action-ID/current-state guard as the other actions. These are deterministic stale-status defects, not timing speculation.

### P2 — R5: Accepted gateway path grammar is still not implemented exactly

`room.js:52–80, 109–113, 187–190`; gateway `native/mjolnir_relay/src/edge.rs:1535–1582`.

`alice/%63am` passes local validation, but the real gateway canonicalizes its admission echo to `alice/cam`; the client compares against the raw string and rejects with `response_mismatch`. Media URL construction also encodes the raw string, not the canonical result. `alice/é` is rejected because the decoder truncates UTF-16 code units into bytes rather than encoding UTF-8. `.hidden/cam` is rejected even though the gateway permits it. Full path bounds use JavaScript character count instead of gateway UTF-8 byte length. Depth and the historical forbidden-escape examples are repaired.

**Smallest repair:** return a canonical path from a byte-correct single-decode implementation, validate raw/full UTF-8 byte and depth bounds, and snapshot/use that canonical path for admission, echo comparison, map keys and media URL encoding. Add allowed escaped ASCII, literal Unicode, leading-dot non-traversal names, and exact byte-boundary cases. No auth bypass is claimed; this is contract/availability correctness.

### P2 — R6: Shared track ownership promised by D2 is still absent

`room.js:262–276, 549–552`.

Return the same track for incumbent and candidate, then fail the candidate offer. The incumbent remains registered/open but its shared track is stopped by candidate cleanup. This is a module dependency-contract reproduction; the supplied page normally requests a fresh getUserMedia stream, so it is not a claim that Chromium returned a shared track in the builder run.

**Smallest repair:** refcount shared tracks as accepted, or explicitly clone into independently owned tracks before recording them and release only those clones. Test failure, supersession, successful replacement and leave. Do not silently narrow the accepted ownership contract.

### P2 — R7: Response-level redirect rejection is incomplete

`room.js:171, 300, 394–410`.

All request types now use `redirect: "error"` and `referrerPolicy: "no-referrer"`; native-fetch redirect refusal is repaired. Admission additionally rejects `response.redirected`. Media and DELETE do not: injected redirected foreign 201/204 Responses commit and report cleanup success in the probe. Response URL provenance is not checked consistently either.

**Smallest repair:** centralize response provenance rejection for credential-bearing requests, covering admission/media/DELETE before trusting headers/body/status. Treat an explicitly redirected or foreign response as failure. This is defense at the injected-fetch/response contract boundary, **not a demonstrated native-browser redirect bypass or credential leak**: conforming native fetch already refuses redirects with the supplied option.

## Repair assessment and evidence boundaries

F1 is repaired at native fetch, incomplete at response validation (R7). F2's prompt camera/PC release, DELETE bound and immediate successor expiry scheduling are repaired. F3's ordinary offer/local/remote exceptions and late successful allocation are repaired, but R1/R2 remain. F4's ordinary disconnected+failed deduplication, one in-flight retry and failed-PC removal are repaired; an incumbent can retry while a candidate fails. F5 snapshots peer inputs, checks freshness at key post-await side-effect boundaries, uses the earliest admission and requires 201. It does not yet provide settlement on every cancelled await (R2). F6 remains R5. F7 local-preview ownership is repaired; remote identity/shared tracks remain R3/R6. F8 improves captions, pending copy, notices, masked/cleared renewal field and playback recovery, but R3/R4 remain.

Builder `2026-11-27-code-ui-fixes/browser.json` is **Chromium against an HTTP fixture**, not the accepted gateway. Its join records WHEP 409 then 201 but `videoWidth=0` and Waiting at the sample. Its driver waits for any Waiting/Playback/Playing text and room status, not decoded video, so this sample **does not distinguish normal startup timing from a persistent media failure**. A Waiting label before decoded playback can be truthful. Replace's snapshot still says Replacing, has Playing with recovery visible, and later Play media says Playing; this establishes recovery interaction, not full successful replacement/media truth. Leave's **44ms** local clearing and later cleanup-timeout status remain valid fixture observations.

Prior builder real-gateway evidence was 640×360 colored frames and approximately 439Hz tone on the older implementation. This reader did not rerun it or upgrade it to this hash. The concurrent builder rerun subsequently landed in **b07cde25 / 1c83ad07**, `2026-11-27-code-ui-gateway/`. I read its OUTCOMES, summary and served hashes; local room.js/boot.js SHA-256 values match the served files. This is **builder-run actual accepted 4bd94d1d gateway evidence**, not this reader independently driving Chromium. It records first decode and post-replacement decode at 640×360 with matching colors and 439Hz audio; forced autoplay rejection then recovery at 1280×720 with 439Hz audio; denied renewal retaining sessions/camera count; successful renewal with later 1280×720 video; and leave with zero PCs/tracks/sessions and eight HTTP 204 cleanup outcomes. The successful-renewal sample has **audioPeakHz=0 and audioRms=0**, so it does not prove restored tone there. The recovery control remains visible after successful playback, corroborating R3's async visibility issue. WHEP unroutable termination logs followed by new track IDs and decoded playback support this local publisher replacement/resubscribe journey. This evidence does not test R1/R2's exceptions/cancellation, expiry UI, or shared tracks; verdict unchanged. The concurrent builder files were not edited.

Provisional source/VM UI score **6/10**: clearer identity, notice, labels and recovery are improvements; system-status truth and reliable recovery still fail major heuristic checks. Resolve R3/R4 and verify actual media, keyboard/focus and responsive behavior before claiming 10/10. This score does not add an unrelated redesign gate.

**Whole-node gates remain separate:** `.14` roster, Safari on phone, three-network/interoperability journey, and eight PeerConnections at 720p. D5 still owes real same-path answer failure, remote-description failure and ICE-timeout observations with existing **and new** subscribers, the new builder run now supplies one local publisher termination/resubscribe observation. Accepted non-atomic relay selection remains accepted; no atomic-handover change is requested. Keep `.15` open; do not close or fold.
