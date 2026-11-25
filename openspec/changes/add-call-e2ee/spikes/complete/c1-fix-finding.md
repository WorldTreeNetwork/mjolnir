# C1 fix round: answer to the 2026-11-24 code review

This round answers `reviews/2026-11-24-c1-code-review.md`, which sent C1 back at `450c69e`. It changes only `clients/call-crypto/reader-policy.ts`, its test file, and the contract (spec, D2, ADR 0017 item 2, tasks). No transport, crypto, storage, timer or deploy work was added. `c1-finding.md` stays as written. This file adds to it.

## Verification

| Check | Result | Log |
|---|---|---|
| `node --test clients/call-crypto/reader-policy.test.ts` (Node 26.3.0) | **63 pass, 0 fail** | `logs/c1-fix-green.log` |
| `bun test clients/call-crypto/reader-policy.test.ts` (Bun 1.3.14) | **63 pass, 0 fail** | `logs/c1-fix-green-bun.log` |
| `tsc --noEmit --strict --target ES2022 --module esnext clients/call-crypto/reader-policy.ts` (TypeScript 6.0.3 via `npx -p typescript@6`) | exit 0, no diagnostics | `logs/c1-fix-types.log` |
| The review's 14 scratch tests, copied unchanged, run against `450c69e` | 8 fail, 6 pass. Reproduces the review | `logs/c1-fix-scratch-red.log` |
| The final test file run against the unchanged `450c69e` module | **28 fail, 35 pass**. Every new defect row is red | `logs/c1-fix-red.log` |

Red came first. I wrote the rows and ran them against the unchanged module, then changed the module. Three rows (I12, I34, I35) first failed on `endInstance`'s new boolean return. I moved those assertions so that the red run fails on the behaviour itself, then ran it again. `c1-fix-red.log` is that second run.

After the fix, the reviewer's scratch file still fails A02, A04 and A06, but only because they use the old API. A02 calls `trackFailure` on a name never passed to `track()`, which is now ignored by design (F3). A04 reads the removed `state`. A06 expects `track()` to keep handing out trackers past the cap. A05 now passes trivially, because `state` is undefined. Rows I32, I37, I36 and I38 carry those inputs on the new API and pass.

## What changed

| Finding | Change (`reader-policy.ts`) |
|---|---|
| F1 | `authenticated()` clears track state only when the mark moves: `if (epoch !== this.#mark)`, checked before the mark is assigned (`:337`). One `#tracks` map, keyed by name, holds each tracker together with its resubscribe stamps, so both have the mark's lifetime. |
| F2 | New `probeEnded(epoch, now)` applies the timeout rule: backoff, no bar (`:291`). `endInstance(epoch)` now only un-accepts the accepted epoch, returns a boolean, and no longer touches `available` (`:285`). Only `withdraw` retracts. If `endInstance` is called for the live probe, the probe stays live until its 1500 ms deadline, so the call still ends in backoff. |
| F3 | At most 128 distinct track names per accepted instance (`LIMITS.tracksPerInstance`). A further name gets a frozen `{kind: "unavailable_retryable", track, reason: "track_limit"}` (`:392`). `trackFailure` ignores a name that has no tracker (`:369`). Existing marks are never dropped. |
| F4 | `state` is gone. `status` returns separate facts `{inviteNeeded, playback, superseded, probing, olderStreamOnly}`, worked out when read (`:156`). `states` maps them to spec names, playback state first, then probing exhaustion (`:171`). `olderStreamOnly` is true when nothing is accepted, no announced candidate is at or above the mark, and at least one announced candidate is below it (`:205`). `authenticated()` returns `"accepted"`, `"refreshed"` or `false` (`:333`, `:346`). Re-accepting the same epoch is `"accepted"`. `resumePublishing` no longer writes any state: `superseded` is computed from the accepted and own epochs (`:359`). |
| F5 | `retryAt = from + min(60 s, 3 s × 2^timeouts)` (`:239`). A deadline timeout measures from `started + 1500`, not from whenever `tick` happens to run, so the result does not depend on call order. |
| L1 | `rejectCandidate` runs `tick` first, then bars any known candidate other than the accepted one, whether or not its probe has already timed out (`:350`). |
| L2 | `announce` returns `"ok" \| "invalid" \| "full"` (`:255`). When the table is full it first purges withdrawn records whose bar and backoff have expired, using the last clock, so no clocked call is needed first (`:266`). |
| L3 | `authenticated` returns `false` unless the epoch is a canonical string (`:332`). `endInstance`, `probeEnded` and `rejectCandidate` make the same check. |
| L4 | When the budget is spent, `trackFailure` returns `retryAt`: the oldest stamp plus 60,000 (`:372`). |
| L5 | `track(name, window, mirror?)` takes the caller's mirror at creation and never throws when the window differs. It returns the existing tracker with its first window, and C2 compares `tracker.window` to report `metadata_difference` (`:387`). |
| Spec | Instance requirement: probe ended by the transport counts as a timeout, 60 s cap, transport end does not retract, caps of 256 candidates and 128 track names. Track paragraph: same-epoch re-acceptance keeps the same consuming generation, marks, mirrors and budgets. Group order: the mirror is not reset by re-acceptance. The window is a reader parameter, **provisionally 120 ms** until C2's integrated run. 128 starts with a fail-closed floor. The review's slower-retransmission numbers. Adapter states: facts side by side, the definition of `older_stream_only`, and first acceptance reported distinctly from a refresh. |
| D2, ADR item 2 | 60 s cap. A transport-ended probe is a timeout. |
| tasks.md | Gate note (still open, waiting for a second read). C1 note. The C2 box gets the frame-index hook with both options (upstream `index` on `Frame`, or an `@internal` `Consumer.make` wrapper that must be pinned and tested; not chosen), plus N1, N2, N3 and wiring notes. The C4 box gets N3, and N1/N2 by reference. |

## New and repaired rows

"Red reason" is the first failing assertion in `logs/c1-fix-red.log`, against `450c69e`.

| ID | Source | Row | Red reason against 450c69e | Final |
|---|---|---|---|---|
| I31 | F1, A01 | same-epoch re-acceptance keeps group/frame marks and mirror (bounce then replay) | `track("audio")` after the bounce returns a **new** tracker | PASS |
| I32 | F1, A02 | same-epoch re-acceptance keeps the resubscribe budget | after the bounce, failure at 7 ms → `resubscribe`, expected `unavailable_retryable` | PASS |
| I33 | F1, honest case | accepting a greater epoch releases the older epoch's trackers and budgets | `trackCount` missing (the tracker half was already G15). Surface red: release on a greater epoch already worked | PASS |
| I34 | F2, A03 | probe ended by the transport backs off like a timeout, never retracts | `endInstance(E3)` on the live probe dropped it, so `nextCandidate(1)` returned E1 immediately (A03: 12 probes in 12 ms) | PASS |
| I35 | F2 | transport end of the accepted instance does not retract its announcement | after `endInstance(E1)`, `nextCandidate(2)` → `undefined`. Still-listed announcement never retried | PASS |
| I36 | F3, A06 | distinct track names per instance are capped; unknown names keep no counters | the 129th `track()` returned a tracker, not the `track_limit` refusal | PASS |
| I37 | F4, A04 | budget exhaustion beside an accepted stream keeps playback and supersession facts | `status` missing (A04 in the scratch red log shows the old alternation) | PASS |
| I38 | F4, A05 | older_stream_only only when no candidate at or above the mark remains | `status` missing (A05 in the scratch red log shows `older_stream_only` with E3 next) | PASS |
| I39 | F4 | authenticated reports first acceptance, refresh and re-acceptance | `true`, expected `"accepted"` | PASS |
| I40 | F4, resume bullet | resume below the accepted epoch stays superseded without waiting for a manifest | `status` missing (the old code wrote `ready` on resume) | PASS |
| I41 | F5, A07 | timeout backoff is capped at sixty seconds | after the 6th timeout, E1 not offered at +60 s (old wait 96 s) | PASS |
| I42 | L1, A10 | authentication failure reported after the deadline still bars sixty seconds | `rejectCandidate(E1, 1600)` after `tick(1500)` → `false` | PASS |
| I43 | L2, A11 | announce distinguishes invalid from full and frees retracted records unclocked | `true`, expected `"ok"` | PASS |
| I44 | L3, A12 | malformed epoch never authenticates | `authenticated(undefined)` → `true` | PASS |
| I45 | L4 | exhausted track resubscription reports when it may retry | refusal has no `track` or `retryAt` | PASS |
| I46 | review coverage gap | manifest at exactly 1500 ms after subscription is late | not red: coverage of the `>= 1500` boundary, which already held | PASS |
| G17 | review coverage gap | start pruned by the window stays refused | not red: coverage, already held | PASS |
| I04 | repair (A13) | re-served older instance does not roll back | not red: now also has the older instance "authenticating" before and after the accepted one ends | PASS |
| I08 | repair | probing timeout or authentication failure keeps accepted playback | `status` missing. The added auth-failure-beside-playback part already held | PASS |
| I12 | repair (F2 effect) | ended selected instance keeps mark | `status` missing. The row now has the relay withdraw the ended announcement, since `endInstance` no longer does | PASS |
| I15 | repair | fast clock blocks honest lower until explicit page reset | `status` missing. It no longer duplicates I12: the lower E2 is never offered while FAST is accepted or after it ends, and a fresh policy accepts E2 | PASS |
| G10 | repair | caller mirror is attached at creation and lives as long as the mark | `track(…, mirror)` ignored the caller's mirror. The old row could not fail (`readonly` field) | PASS |
| G16 | repair (L5) | changing window keeps the first window and mark | old `track()` threw `TypeError` | PASS |

Other rows changed only to fit the API: I05, I11, I25 and I28 (`announce` results), I09, I13, I14 and I16 (`status`/`states` in place of `state`), I17, I18, I19, I20, I26, I30 and G15 (`track()` before `trackFailure`, which F3 requires). I14 is kept. As the review says, the real evidence for "reload is a fresh reader" is that the module has no module-level, stored or global state (`grep`: none), not this row.

## Notes for the second read

- **Re-probing an ended accepted epoch.** Once `endInstance` stops retracting, an ended accepted epoch that is still announced is offered again at once, with no backoff. That is the honest-reconnect path, and each cycle costs one of the 12 probes. A reader whose own session drops should withdraw every announcement (the `withdraw` doc and the C2 box say so). Otherwise it probes into a dead transport and builds up backoff.
- **`track()` takes no epoch**, unlike `trackFailure` (I30). A stale callback from a retired subscription that calls `track()` would get the current instance's tracker. Its frames are authenticated under the old consumer, so this is at most a self-inflicted refusal, not a replay. C2 should key callbacks by epoch. This is not in the review, so it was not changed here.
- **`status` is read as of the last clocked call.** `probing: "budget_exhausted"` can stay showing after the window has passed until the next clocked call. Every time stays an explicit input (review N4).
