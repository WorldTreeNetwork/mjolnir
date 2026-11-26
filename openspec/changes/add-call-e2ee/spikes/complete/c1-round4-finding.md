# C1 round 4 (answers reviews/2026-11-25-c1-diff-check-3.md, bead mjolnir-rurh.9.3)

Red: `logs/c1-round4-red.log` — the review's seven exact inputs (eight rows) against `acdd849`, 8 of 8 fail.
Green: `logs/c1-round4-green.log` — bun 107/0, node 107/0 (96 table rows, 10 randomized blocks, 1 reach printout), strict `tsc` exit 0 over the module and both test files, and over the module alone.
Mutations: `logs/c1-round4-mutations.log` — five reintroduced defects, each caught in all ten blocks.

## Fixes

| Review item | Change |
|---|---|
| High: string `authenticated` | `GroupTracker.frame` refuses any non-boolean outcome with a TypeError and delivers only for primitive `true`. D08 now throws field-level junk (strings, numbers, objects, `null`, `undefined`, boxed booleans, bigints) at every field of every object-shaped argument (frame identity, scope). |
| Retry budget | Charging moved from the failure to the start. A failure leaves one grant (`resubscribe` or `retry`); `track()` consumes a `resubscribe` grant and charges that start once; `retryTrack()` needs an outstanding `retry` and charges it. A second start of a healthy name returns `live`; a retry without exhaustion is refused. `track()` takes an optional `now` so the charge is stamped when the start really happens. |
| Clock on refused calls | `endInstance`, `probeEnded`, `authenticated`, `rejectCandidate`, `trackFailure` and `retryTrack` check authority and arguments before any tick. `subscribe` decides eligibility with a non-mutating `#eligibleAt(now)`, so a valid-shaped but ineligible start changes nothing. A live probe's own callback at or after its deadline applies the timeout and returns `false` (F06). |
| `reconcile([42])` | One pass validates every element; a non-string, malformed path, bad epoch for this scope or throwing iterator refuses the whole call before any change. A well-formed path of another scope is ignored. |
| Unbounded scratch | The same pass keeps only the greatest 256 distinct epochs (binary-search insert). An epoch below a full top-256, or evicted from it, is provably distinct from all kept ones, so overflow is exact with bounded memory. F08 runs 65,536 lazy paths with duplicates. There is no heap assertion; the bound is by construction. |
| Fence after rotation | A report about any epoch below the mark is refused. That keeps the fence without remembering acceptance history. |
| Numeric label | Scope fields must be the declared primitives; absent scope is `undefined` only. |

## The randomized test, rebuilt

`reader-policy.random.test.ts` now carries an independent model: the live probe and its start time, the accepted session, which track handle is current (checked against `handle.current` for every handle every step), each name's outstanding grant, actual replacement start times, one-shot reports and both rejection fences. Generation is weighted by state (idle → announce and probe; probing → answer in time, reject, end, or let the deadline pass; session → frames with 30% replays, track starts, failure storms through exhaustion, clocked retries, same-epoch end and re-accept, rotation, in-session reconcile, late reports). 15% of steps are fully random with stale, cloned, forged, foreign and junk arguments, including junk `authenticated` values.

There is no pre-call tick: clock advance is a generated action. A call the model says has no authority must change nothing, the policy clock included. Replacement starts are counted by the model and capped at 6 per rolling minute. Status is checked in both directions, including `olderStreamOnly`, `probing`, `playback`, `superseded`, `budgetExhausted` and `candidatesIncomplete`. Bars are also capped at 24 (two minutes of probes).

Reach over the default 200 seeds × 2,000 steps (Astra measured the old generator at zero for same-epoch re-acceptance, exhaustion and retry):

| Counter | Count |
|---|---:|
| probes issued | 24,182 |
| first acceptances | 200 |
| same-epoch re-acceptances | 3,403 |
| rotations | 9,448 |
| deliveries | 36,910 |
| replays refused | 10,413 |
| track starts / charged replacement starts | 78,642 / 56,591 |
| track exhaustions / clocked retries | 5,751 / 3,457 |
| overflow refusals / complete reconciliations | 47,289 / 13,918 |
| late reports fenced | 19,631 |
| stale / junk calls refused unchanged | 60,546 / 5,325 |

Each block asserts a minimum for every counter, so a generator change that loses a transition fails.

Mutations (one at a time, unchanged test, default size):

| Mutant | First catch |
|---|---|
| F1: clear track state on every acceptance | seed 1 step 197 (`retryTrack`: the model's grant was lost) |
| track handle not retired on failure | seed 1 step 14 |
| duplicate rejection extends the bar | seed 1 step 182 |
| stale `endInstance` advances the clock | seed 1 step 91 |
| string `authenticated` coerced | seed 3 step 1944 |

The randomized test found no new policy defect this round. Its first runs failed on harness bugs: a multi-call step compared against the wrong snapshot, and a random step acted on the current handle without updating the model. Both are fixed.

Cost: about 7 s in node and 18 s in bun for the default run (each block under 1 s in node and about 1.6 s in bun). That is above last round's 4.7 s, because each step now does more work. Two optimisations brought it down from 25 s: lazy failure messages in the hot loops, and a realistic reconcile set.

## Disagreement

None on the findings. One addition beyond the brief: `track()` gained an optional `now`. Without it a charged start is stamped at the last clocked call, and a delayed start could let a seventh real start into a rolling minute.
