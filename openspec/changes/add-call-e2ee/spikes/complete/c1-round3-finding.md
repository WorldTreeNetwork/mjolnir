# C1 round 3 (answers reviews/2026-11-25-c1-diff-check-2.md)

Red: `logs/c1-round3-red.log` — A2–A10 as rows against `3cbd279` (`round3-red.test.ts`, not kept): 8 of 8 fail; strict `tsc` over module and tests: 15 errors. `logs/c1-random-red.log` — E01, found by the randomized test, red before its fix.
Green: `logs/c1-round3-green.log` — bun 95/0, node 95/0 (85 table rows + 10 randomized blocks), strict `tsc` exit 0 over the module and both test files, and over the module alone.
Soak: `logs/c1-random-soak.log` — 2,000 seeds × 3,000 steps, clean.

## Fixes

| Review | Change |
|---|---|
| A2 | `trackFailure` retires the handle on its first terminal report, in both branches. The exhausted branch records `blockedUntil`; `track()` refuses that name with `retry_wait` until then, and `retryTrack(sub, name, now)` is the clocked path back. Mark, mirror and budget stay with the name. |
| A3 | One report per probe (`Sub.reported`). A repeat is refused and never extends the bar. |
| A4 | Each attempt has a sequence number. Accepting attempt *n* of the mark epoch deletes a bar set by an earlier attempt and records `#markAcceptSeq`; reports from attempts older than that are refused, including after the session ends. A report while the replacement is only probing still bars (C07 unchanged). |
| A5/A9 | `candidatesIncomplete` is set by `full` and by evicting an **active** below-mark record (withdrawn ones are evicted first). Only `reconcile(activePaths)` clears it, and only if every active epoch fits; it admits greatest first. A string is refused (it is an iterable of characters). |
| A10 + audit | Every method type-checks its arguments (issued handle by reference, finite clock, valid epoch, string name, bigint window, iterable non-string set) before any tick or change. D08 throws junk at every public method and compares full snapshots. |
| A6 | A session of 10 s or more resets the rapid streak to 0. |
| tsc | `must()` narrows `Subscription | false`; strict check now covers the tests. |

## The randomized test (`reader-policy.random.test.ts`)

Mulberry32, no dependency. Per step it advances the clock (including zero steps, so equal-time orderings are common) and calls one of the public methods with an issued, stale, cloned, forged, foreign or junk handle. Bursts of 300 announcements and 300-path reconciliations cover overflow. After every step it checks:

- a call that refused (false, `ignored`, `stale`, `invalid`, a refusal object, or a Type/Range error) changed nothing observable, including track handles' currentness and marks;
- the mark moves only on an `accepted` result and never decreases;
- no `(track, group, index)` is delivered twice within one mark;
- caps: 256 candidates, 128 tracks, 12 attempts, 128 starts and 6 retry stamps per track;
- no bar, backoff, pace or track retry is more than 60 s ahead; a repeated report returns false;
- status agrees with the internals (`budgetExhausted`, `candidatesIncomplete`, `playback`, and `olderStreamOnly` only with a complete view, no playback and no active candidate at or above the mark).

**What it found:** one defect. `tick()` was not idempotent: it purged withdrawn records before expiring the probe deadline, so a withdrawn epoch whose probe expired in that tick was forgotten only by the next call at the same time. Seed 1, step 285, surfaced it as a refused `endInstance` that changed state. Row E01; the purge now runs after the deadline.

**That it can find things:** reintroducing three of this round's defects one at a time was caught within two seeds each: one-shot report removed (seed 2 step 43), terminal track retirement removed (seed 2 step 407), the `subscribe` validity check removed (seed 2 step 1344, a junk handle accepted and the mark went backwards).

Default run: 200 seeds × 2,000 steps, about 4.7 s in node and 8 s in bun. It is split into ten tests so bun's 5 s per-test timeout is never near. Replay one seed with `RANDOM_SEED=<n>`; scale with `RANDOM_SEEDS` and `RANDOM_STEPS`.

## Not changed

- Handles are bearer references inside trusted adapter code; a TypeScript private brand would catch accidental reconstruction at compile time. Runtime refusal already holds, so I left the type structural.
- The cross-kid per-label budget stays C4 work.
