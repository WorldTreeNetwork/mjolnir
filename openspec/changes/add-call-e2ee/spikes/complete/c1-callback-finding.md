# C1 callback-identity round (answers reviews/2026-11-25-c1-diff-check.md)

Red: `logs/c1-callback-red.log` — S1–S6 written as rows against `d4333b2` (`callback-red.test.ts`, not kept): 9 fail, 1 pass. The pass is S3b without a tick, the half the reviewer reported as barring; its ticked twin failed, which is the defect.
Green: `logs/c1-callback-green.log` — bun 75/0, node 75/0, strict tsc exit 0. The 63 earlier rows were migrated to handles with their inputs and assertions unchanged except where noted below; C01–C12 carry S1–S6.

## Design

One opaque handle per subscription, as the brief suggested.

- `subscribe(epoch, now)` returns a `Subscription` (frozen `{epoch}`; identity is the object). Every manifest callback carries it: `authenticated`, `probeEnded`, `rejectCandidate`, `endInstance`. On acceptance the probe handle becomes the session handle. Anything that is not the live probe or the accepted session is refused.
- `track(session, name, window, mirror)` returns a `TrackHandle` for one track subscription, or `{kind:"stale"}` when `session` is not the accepted session. Marks, mirror and resubscribe budget stay with the name for the mark's life. The handle is current only while its session is accepted and it is the latest handle for that name. A stale handle's `frame()` returns `stale` and changes nothing. The policy never hands out the `GroupTracker` itself, so a cached reference cannot bypass the check.
- Bars moved out of the candidate table into `#bars`, so purge order cannot shorten them. Bars are created only by issued probes, at most the probes of two minutes.
- Pacing of the accepted epoch (`#pace`) applies only to the mark epoch and resets when the mark moves.
- Status: `probing` and `budgetExhausted` are separate. `candidatesIncomplete` is set by a `full` refusal and cleared by the next admitted record. `olderStreamOnly` requires a complete view.

## Rows whose shape changed in migration

- Every `track(name, …)` now takes the session. Repeated `track()` for one name returns a new handle, not the same object, so the old `assert.equal(tracker(...), g)` identity checks became mark/mirror checks plus `g.current === false` (I17, G10, G15, G16, I31, I36).
- I09 and I37: `probing: "budget_exhausted"` became `probing: "idle", budgetExhausted: true`.
- I36: the "unknown name keeps no counter" probe uses a non-handle object, since a name with no tracker has no handle.

## Open, not changed here

- A late rejection from an earlier attempt bars the epoch even if a later attempt of that epoch is accepted. It does not end that session. Only re-probing after a future end waits for the bar. I think that is right: the relay served forged content under that epoch. Flagged for the next reader.
- `candidatesIncomplete` clears on the next admitted record, not on a full reconciliation. C2 owns re-offering the active set after `full`.
