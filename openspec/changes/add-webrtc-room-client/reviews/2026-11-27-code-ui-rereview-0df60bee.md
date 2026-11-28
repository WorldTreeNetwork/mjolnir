# Independent narrow CODE/UI re-review — ACCEPT

Exact reviewed implementation: **0df60bee32e02b8908e2438259ed8e3d10b38adc**. Fresh user-assigned independent reader; parent Codex authored. Read AGENTS/bd, accepted contract/advise-3 and D5, prior SEND-BACK at 66ca67ae (`2026-11-27-code-ui-rereview-1385fab1.md`), and the exact 66ca67ae..0df60bee diff. Scope is the two browser lifecycle fixes on mjolnir-rurh.15. No product edits, agents, deployment, closure or fold.

## Verdict and independently executed evidence

**ACCEPT the narrow code repairs. No concrete remaining defect found in this diff.**

- `npm test --prefix native/mjolnir_room`: **45/45 pass**.
- Unmodified `2026-11-27-rereview-1385fab1-probes.mjs`: **17/17 pass**, including the integrated real-module/page two-peer retry interleaving and exact-count Leave cleanup probes.
- New adjacent `2026-11-27-rereview-0df60bee-probes.mjs`: **4/4 pass**. Reuses the earlier dependency/DOM harness, with fresh boundary assertions. Supersession tested with Location known before retirement and headers arriving after retirement; each old allocation receives exactly one DELETE with its own bearer, late body completion has no effect, successor sessions/tracks remain owned, and repeated teardown does not duplicate cleanup. Two integrated failure probes deliver retry tracks while negotiation is pending, disconnect the other real fake-PC peer to trigger paint, then reject the answer or fail ICE. The pending stream survives paint; settled failure clears srcObject, playback-blocked state and recovery, closes the failed PC and does not duplicate session deletion.

These execute production module/page source using Node dependency and VM DOM doubles. They are not native-browser execution or proof of audible media.

## Why the repairs hold

`discardAttempt` now claims cleanup only while the returned session object remains in `gen.sessions`. `deleteOwned` removes known allocations synchronously before its asynchronous DELETE work. Thus an awakened retired negotiation cannot delete those again. Conversely, a late trusted 201 registers a new session object after retirement; it still belongs to the retired generation until discard claims it, so its one cleanup is preserved. The ordering is synchronous around membership/removal; no await opens a duplicate claim window.

`paint` still immediately retires mismatched generation/attempt owners. Matching owners with stale empty state are retained only while inflight. `playPeer` clears inflight before notifying either success or failure; transient failure sets empty and schedules retry, terminal failure sets failed/empty. Settled empty/failed views therefore still retire. The unchanged integrated positive probe verifies successful retry ownership survives; the fresh rejection/ICE probes verify this does not retain failed retry streams.

Earlier lifecycle checks remain green: constructor/body failure cleanup, cancellation of gathering/readiness, bounded SDP including admission expiry, no-track generation retirement, detached element/play completion guards, shared-track ownership, canonical paths, response provenance, expiry UI, and old Leave versus new Join. Historical probes are preserved unchanged.

## Evidence readiness and remaining gates

Ready for the parent to accept these two code fixes and continue the existing evidence work. This does not grant whole-node/media acceptance.

The separate builder diagnosis at 6204a8aa (`2026-11-27-tone-diagnosis/OUTCOMES.md`) reports new current-track 439 Hz recovery after replace and renew, with a silent old-track gap and resubscription within 12 seconds. Its recorded sources are **6f98d267**, not this exact implementation. It is useful separate builder evidence, not an independent media run here; unit success is not used to infer audio success. Current-hash colours/tone evidence and the previously owed D5 candidate-failure observations with existing/new subscribers remain outside this narrow acceptance. .14, Safari phone, three networks and eight-PC gates remain unchanged. Keep .15 open; no fold or deployment authority.
