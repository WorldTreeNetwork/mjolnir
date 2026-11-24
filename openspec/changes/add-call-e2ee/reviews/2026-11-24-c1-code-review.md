# add-call-e2ee — C1 code review, 2026-11-24

> **REVIEW:** send-back
> **READER:** claudeAgent/claude-fable-5-2, fresh context, read-only
> **SPAWN:** a T3 Code delegate thread on the Claude Code harness. Not launched by `spawn.py`, so there is no spawn directory.

Code read: `clients/call-crypto/reader-policy.ts` (304 lines) and `reader-policy.test.ts` (532 lines) at `851e9f8` (`HEAD` of `main` and of `origin/main` after `git fetch`). Author: Codex `gpt-6.1-sol`. Line numbers below are in `reader-policy.ts` unless a file is named.

I did not edit the module, its tests or the contract. My scratch tests are not committed. Each one is given below with its exact inputs so the author can turn it into a row.

## Verdict in one screen

The design of the module is right and most of it is correct. One defect breaks a requirement the module exists to hold, so it goes back before C2.

1. **F1, high.** When the accepted instance ends and the same epoch is accepted again, the module throws away every group/frame mark for that epoch. A relay can cause this whenever it likes by closing the broadcast and announcing it again. The reader then accepts frames it already opened, which is the replay the group-order requirement forbids (`spec.md:123`). An honest reconnect takes the same path, because `spec.md:151` lets a publisher keep its generation across a reconnect. The fix is one condition.
2. **F2 to F5, medium.** A probe that the transport ends gets no backoff. The per-instance track maps have no bound. The single state value loses information that C2 will wire to the page. The timeout backoff has no cap, so its effect outlasts the interference.
3. The rest is low or is a note for C2 and C4.

The send-back is narrow: F1 to F3 are code plus a row each, F4 is a decision on the shape of the state before C2 reads it, F5 is one sentence in the contract and one `Math.min`. A second read can be a diff check of those five.

## What I ran

| Check | Result |
|---|---|
| `bun test clients/call-crypto/reader-policy.test.ts` (Bun 1.3.14) | 46 pass, 0 fail |
| `node --test clients/call-crypto/reader-policy.test.ts` (Node 26.3.0) | 46 pass, 0 fail |
| `tsc --noEmit --strict --target ES2022 --module esnext clients/call-crypto/reader-policy.ts` (TypeScript 6.0.3) | exit 0 |
| Storage, timers, ambient clocks, network, crypto in the module (`grep`) | none |
| Pinned moq at `~/.cargo/git/checkouts/moq-71b39088639cef96/4a6f522`, `git rev-parse HEAD` | `4a6f522483168ace392718d68b58a402533c897d` |
| 14 scratch tests, `node --test` | 8 fail against the spec, 6 pass. Listed under "Scratch tests". |

Not done: no browser, no relay, no production host. The I8 shaper was not re-run in the moq workspace. I re-ran its delivery model against the C1 `GroupTracker` without crypto (A14).

## What the module must guarantee, and whether it does

Written from the contract before reading the code.

| # | Guarantee | Source | Holds |
|---|---|---|---|
| 1 | An announcement never moves the mark | `spec.md:22` | Yes (I01, A13) |
| 2 | Candidates at or above the mark are tried greatest first, one at a time | `spec.md:22` | Yes |
| 3 | Only the first authentic `bridge.tracks` frame accepts. The 1500 ms run from that subscription | `spec.md:22` | Yes (I21, I23) |
| 4 | Authentication failure bars for 60 s. A timeout does not bar and backs off from 3 s, doubling | `spec.md:22` | Yes, with F5 and L1 |
| 5 | Every probe counts in 12 per label per 60 s | `spec.md:22` | Yes per object. See N3 for two kids |
| 6 | Failure or exhaustion never clears the mark or the accepted stream | `spec.md:22` | Yes for the mark and `acceptedEpoch`. The state value is F4 |
| 7 | No automatic render below the mark, even when the below-mark instance authenticates | `spec.md:22` | Yes (A13) |
| 8 | `older_stream_only` when only older instances remain | `spec.md:22` | No in one case (F4) |
| 9 | Reload is a fresh reader | `spec.md:22` | Yes. No module-level or stored state |
| 10 | Publisher is superseded only by an authenticated greater instance | `spec.md:22` | Yes (I13) |
| 11 | A track failure inside an accepted instance keeps acceptance, mark and mirror. At most 6 resubscriptions per track per 60 s | `spec.md:24` | Yes, until the instance bounces (F1) |
| 12 | The group mark is (group start, last authenticated frame index) and moves only on authentication | `spec.md:123` | Yes |
| 13 | An equal group continues strictly above its saved index. No opened index reopens | `spec.md:123` | Yes inside one acceptance. **No across a same-epoch re-acceptance (F1)** |
| 14 | Zero reorder for manifest and catalog | `spec.md:123` | Yes |
| 15 | Media window of remembered starts. A start more than the window behind is refused | `spec.md:125` | Yes (A08, A14) |
| 16 | The mirror lives as long as the mark | `spec.md:123` | No across a same-epoch re-acceptance (F1) |
| 17 | Every collection is bounded | brief, `design.md:178` | Candidates, attempts and remembered starts: yes. Tracks and resubscribe counters: no (F3) |
| 18 | Every time is an explicit input | brief | Yes |

## Findings, most severe first

### F1 (high). Re-accepting the same epoch erases its group/frame marks, mirrors and resubscribe budgets

`reader-policy.ts:245-249`:

```ts
// Older instances can never be selected again; release their cached mirrors/budgets.
if (this.#accepted !== epoch) {
  this.#tracks.clear();
  this.#resubs.clear();
}
```

This branch is reached only after `epoch === this.#accepted` has returned at line 239, so the condition is always true. The comment is right when the new epoch is greater than the old one. It is wrong when `#accepted` is `undefined` and `epoch === #mark`, which is what happens after `endInstance` (`:177-188`).

Failing input (scratch A01):

1. `announce(path(E1))`, `subscribe(E1, 0)`, `authenticated(E1, "bridge.tracks", 1)`.
2. `audio = track("audio", 120n)`. Deliver groups `0n, 20n, …, 1000n` at index 0. `frame({group: 1000n, index: 0})` returns `duplicate`, as it should.
3. `endInstance(E1)`, `tick(10)`, `announce(path(E1))`, `subscribe(E1, 20)`, `authenticated(E1, "bridge.tracks", 21)`.
4. `track("audio", 120n)` returns a **new** tracker. `frame({group: 0n, index: 0, authenticated: true})` returns `deliver`. Its mark is `{group: 0n, index: 0}`.

Who can cause it: the relay, at will and without a key. It closes the broadcast, the adapter reports `endInstance`, the relay announces the same path again, and one probe later every earlier group of that instance opens again, with any presentation time the relay chooses (timestamps are not authenticated). That is advise-2 N3: "replaying something a person said ten minutes ago". It also happens with no attacker. `spec.md:151` allows a live reconnect to keep its generation, and a reader whose own session drops reports every instance as ended.

The same reset empties `#resubs`. Scratch A02: six failures on `audio` at `now = 2`, a seventh at `now = 3` returns `unavailable_retryable`, then `endInstance(E1)`, `tick(4)`, `announce`, `subscribe(E1, 5)`, `authenticated(E1, …, 6)`, and six more calls at `now = 7` return `resubscribe`. Each bounce costs one of the 12 probes, so the bound per track per minute becomes about 72, not 6.

Fix: clear only when the mark moves, that is `if (this.#mark !== epoch)`, evaluated before `this.#mark = epoch`. Add a row: marks, mirror identity and the resubscribe budget survive `endInstance` and re-acceptance of the same epoch. Add a second row for the honest case: accepting a greater epoch still releases the older one's state (G15 covers the tracker, nothing covers `#resubs`).

For C2: the same re-acceptance must reuse the same consuming generation. A new one resets the failed-open budget, which `spec.md:24` forbids on the track path and which the contract does not yet say for this path.

### F2 (medium). A probe that the transport ends gets no backoff, and `endInstance` also retracts the announcement

`reader-policy.ts:177-180`. `endInstance` clears a live probe and sets `available = false`. It records neither a timeout nor a bar. Its doc comment says it reports the accepted broadcast ending, but it is the only call that fits "the manifest subscription errored".

Failing input (scratch A03): `announce(path(E1))` (real). Then, for `i = 0..`: `announce(path(E3))`, `nextCandidate(i)` returns `E3`, `subscribe(E3, i)`, `endInstance(E3)`. Result: 12 probes of the one forged epoch in 12 ms, `state` is `unavailable_retryable`, and `nextCandidate(12)` is `undefined`, so the real `E1` is not tried for the rest of the minute.

This gives the relay nothing it lacks: advise-3 already accepts that 12 forged announcements spend the budget in 18 s. Two things make it worth fixing. An honest publisher that restarts mid-probe is hammered 12 times in a burst and the label is then unavailable for a minute. And `spec.md:22` gives only two outcomes for a probe, bar or backoff, so a third outcome with neither is outside the contract.

Second effect of the same lines: after `endInstance`, the candidate is unavailable until `announce` is called again. If the relay still lists the announcement (the spike's F2, stale announcements), no new announce event arrives and the candidate is never tried again.

Fix: add `probeEnded(epoch, now)` that applies the timeout rule (backoff, no bar), or give `endInstance` a clock and have it do that when the epoch is the live probe. Do not touch `available` there: only `withdraw` should. Add a row.

### F3 (medium). The per-instance track maps have no bound

`reader-policy.ts:92-93`, `:279-283`, `:292-302`. `#tracks` and `#resubs` gain one entry per distinct track name and are emptied only when a greater instance is accepted. `trackFailure` stores an entry for any string, including one that was never passed to `track()`, and keeps the entry after its timestamps expire.

Failing input (scratch A06): accept `E1`, then for `i = 1..200000`: `track("t" + i, 120n)`, one delivered frame, `trackFailure(E1, "t" + i, 2)`. All 200,000 trackers are retained (`track("t0", 120n)` still returns the first object) and the heap grows by about 160 MB.

Who can make it grow: a credential holder publishing under its own label, including a removed member during the 10-minute retention. The manifest allows 32 names per snapshot and nothing limits how often a snapshot changes, so each snapshot can list 32 new names. A relay without the secret cannot, because names come from the authenticated manifest.

The bound must not drop marks of unlisted tracks: a re-listed track would then accept replayed frames. Fix: cap the number of distinct track names per accepted instance (I suggest 128, four times the manifest bound) and refuse a new name beyond it with a track-scoped `unavailable_retryable`. Have `trackFailure` ignore a name that has no tracker, and delete a `#resubs` entry when its list is empty. Add the cap to the spec beside the 256 and 128 below, and a row.

The other collections are bounded:

| Collection | Bound | At the bound |
|---|---|---|
| `#candidates` | 256 (`:165`) | A new announcement is refused. See L2 |
| `#attempts` | 12 | `nextCandidate` returns `undefined` |
| One `#resubs` list | 6 | `unavailable_retryable` |
| `GroupTracker.#frames` | 128 (`:66-71`) plus the window prune (`:62-63`) | The oldest remembered start is evicted and a floor rises to it. Anything at or below the floor is refused for good. This fails closed |

Refused-epoch sets and removed labels are not kept by this module. Bars live on candidate records. Removed labels are C4.

### F4 (medium). One state value cannot say what C2 must show

`reader-policy.ts:205-208`, `:183-186`, `:221-225`, `:274`. `state` is one enum for the whole label.

- Scratch A04. Publisher self-watch: `new InstancePolicy(scope, E1)`, accept `E2` (state `superseded_by_another_instance`), then 11 forged greater candidates each probed and rejected at `now = 10..20`, then `nextCandidate(30)`. `acceptedEpoch` is still `E2` and `state` is `unavailable_retryable`. `authenticated(E2, "bridge.tracks", 31)` puts it back to `superseded_by_another_instance`, and `nextCandidate(32)` sets `unavailable_retryable` again. So while a stream plays, the label alternates once a second between "unavailable" and its real state, and the relay chooses when.
- Scratch A05. Accept `E2`, `announce(E1)` (older), `announce(E3)` (newer, never probed), `endInstance(E2)`. `state` is `older_stream_only` although `nextCandidate(2)` returns `E3`, and it stays `older_stream_only` during the probe of `E3`. `spec.md:22` says "when only older instances remain".
- `resumePublishing` (`:274`) sets `ready` while the accepted epoch is still greater than the new one. The next manifest frame corrects it (I16), so the page shows "ready" for up to a second on each resume in the fast-clock case.

`spec.md:22` does require `unavailable_retryable` on exhaustion "without clearing the mark/accepted stream", and the module keeps both. The defect is that the report replaces the playback state instead of standing beside it. `spec.md:141` asks for states "with affected label/track scope".

Fix: expose separate facts, for example `playback: "none" | "ready"`, `superseded: boolean`, `probing: "idle" | "probing" | "budget_exhausted"`, `olderOnly: boolean`, and compute `olderOnly` as "no available candidate at or above the mark, and at least one below". Have `authenticated()` return which of "accepted", "refreshed" or `false` happened, so C2 and C4 can act on first acceptance without diffing. Decide this before C2 reads `state`.

### F5 (medium). The timeout backoff has no cap, so its effect outlasts the interference

`reader-policy.ts:195`: `c.retryAt = now + 3000 * 2 ** c.timeouts`. `timeouts` returns to zero only on acceptance or when a withdrawn record is purged.

Failing input (scratch A07): one real candidate `E1` whose manifest the relay delays past 1500 ms on every probe. The waits after successive timeouts are 3, 6, 12, 24, 48, 96, 192 and 384 s. After 12.9 minutes of delay the next wait is 768 s, during which the reader does not try the real instance even if the relay has stopped.

The code follows `spec.md:22` as written ("doubling on successive timeouts"). The contract is what is missing a cap. Advise-3 accepted the probe budget because "no state outlasts the forgery, because the reader recovers within 60 seconds". Without a cap that no longer holds. On an honest poor link, three slow starts cost 24 s.

Fix: cap the backoff at 60 s (the rolling window) in `spec.md:22`, D2 and ADR item 2, and in the code. Add a row.

### Low

- **L1. The 60 s bar depends on call order at the deadline** (`:261-263` against `:192`). Scratch A10: `subscribe(E1, 0)` then `rejectCandidate(E1, 1600)` returns `true` and bars for 60 s. With `tick(1500)` first, the same call returns `false` and the candidate is retried at 4.5 s. A relay that delivers its bad frame just after the deadline gets the 3 s schedule. Fix: have `rejectCandidate` bar a known candidate whether or not it is still the live probe.
- **L2. `announce` returns `false` for both a malformed path and a full table, and the table is purged only by a clocked call** (`:154-168`, `:134-142`). Scratch A11: 256 forged announcements, then `announce(path(E1))` is `false`, the same as `announce("alice/call")`. After the relay withdraws all 256, `announce(path(E1))` is still `false` until some clocked call runs. Then it is `true`. C2 cannot tell "retry later" from "ignore". Fix: return `"ok" | "invalid" | "full"`, and state in the doc that C2 offers every still-active announcement again after `full`.
- **L3. `authenticated(undefined, …)` reports `ready` with nothing accepted** (`:239`). Scratch A12: on a fresh policy it returns `true` and `state` becomes `ready` while `acceptedEpoch` is `undefined`. TypeScript prevents it and plain JavaScript does not. Fix: return `false` unless `validEpoch(epoch)`.
- **L4. `unavailable_retryable` from `trackFailure` carries no retry time** (`:282`). The caller has to report another failure after a minute to ask again (I19 does exactly that). Return `retryAt`, the oldest stamp plus 60,000.
- **L5. `track()` throws when the window differs** (`:297`) and cannot take the caller's mirror (`:300`). The window comes from the manifest timescale, which the publisher of that label writes. C2 must catch it, keep the first window and report `metadata_difference`. Let `track()` accept the mirror, or document that C2 keys a `WeakMap` on `tracker.mirror`.

## Notes that are not defects

- **N1. Manifest one frame per group.** `spec.md:65` requires it. A zero-window tracker delivers index 1 of the same group (scratch A09), because it cannot tell the manifest from the catalog. C2 must enforce it, or `GroupTracker` takes a flag.
- **N2. Window conversion.** `floor(120 × timescale / 1000)` is exact for integer group starts. A media track whose manifest timescale is `null` has no conversion in the contract. Say what C2 uses (I suggest zero) in `spec.md:125`.
- **N3. Budget scope.** One object is one kid. During retention C4 holds an old-kid and a new-kid policy for one label, so the label gets 24 probes a minute against "12 per label" in `spec.md:22`. Share the budget, or change the sentence to "per credential and label".
- **N4. The clock.** Every time is an argument. NaN, infinite, negative and backward values throw `RangeError` before any change (I24). Nothing wraps. Equal times are allowed. C2 must pass `performance.now()`, not `Date.now()`: a wall clock stepped backwards makes every clocked call throw until it catches up. `announce`, `withdraw`, `endInstance`, `resumePublishing` and `track` take no clock, which is the cause of the purge lag in L2. Group windows use authenticated group starts, not time.
- **N5. Things the spec does not ask for.** The 256 and 128 caps, the eviction floor, the split of `withdraw` from `endInstance`, and scope validation are all additions I would keep. The caps belong in the spec. The label pattern matches `lib/mjolnir/relay/mint.ex:6`. The epoch pattern and string ordering match pinned `js/e2ee/src/epoch.ts:14-17`. `preserveMark: true` and `preserveMirror: true` on the action are decoration.

## The media window (brief items 2 and 6)

**Can a relay use the window to replay, or to make a reader accept a frame twice?** No, inside one acceptance. Scratch A08 drove 200,000 random authenticated `(group, index)` pairs through each of four windows (`0n`, `120n`, `5000n`, `10n ** 12n`): no pair was delivered twice, the index never went backwards inside a group, and at most 128 starts were remembered. A start leaves memory only by falling behind the window or below the eviction floor, and both refusals are permanent because the newest start never decreases. Across a bounce it can, which is F1.

**Is 120 ms justified by `i8-finding.md`?** It is justified as the answer to that model, and the finding says so honestly. It is not a measurement of a network. In the shaper, a group arrives at its start plus 0 to 50 ms of jitter, plus 80 ms for 2% of groups. The largest lateness is therefore under 130 ms, so with 20 ms groups no group is ever more than 120 ms behind the newest one. "9000 of 9000 at 120 ms" follows from the chosen 80 and 50. The same model against the C1 `GroupTracker` (scratch A14, seeds 17, 42 and 2026, 3000 groups each):

| Retransmit delay | Jitter | Loss | Window | Delivered |
|---|---|---|---|---|
| 80 ms | 0–50 ms | 2% | 120 | 9000/9000 (7 starts remembered), matching I8 |
| 80 ms | 0–50 ms | 2% | 0 | 7194/9000, matching I8 |
| 100 ms | 0–50 ms | 2% | 120 | 8995/9000 |
| 150 ms | 0–50 ms | 2% | 120 | 8873/9000 |
| 250 ms | 0–50 ms | 2% | 120 | 8821/9000 |
| 80 ms | 0–100 ms | 2% | 120 | 8986/9000 |
| 80 ms | 0–50 ms | 5% | 120 | 9000/9000 |

So the window stops helping once a retransmission takes longer than about 100 ms, which a mobile link will do. Two more limits of the evidence: I8 used its own `Mark` class (`i8-shaper.ts:24-33`), not the C1 module, and the shaper has no congestion, where lite-05/06 serves newest first and older groups fall further behind.

**Should the spec say the window is provisional?** Yes. `spec.md:125` states 120 ms as a SHALL and gives the caveat one sentence later. Change it to say that the value is provisional and is confirmed or revised by C2's integrated run under real impairment, and that the window is a parameter of the reader. The module already takes it as an argument, so a change costs nothing in C1.

## The frame-index claim (brief item 7)

Confirmed in the pinned source. `js/e2ee/src/group.ts:12-20` declares the public `Frame` as `timestamp` and `plaintext` only. The consumer reads the index from the net layer (`:161`, `readFrameIndex`, declared at `js/net/src/group.ts:1438`), uses it for the nonce (`:172`), and drops it at `:179`. C2 cannot count from zero, because a group can resume above frame 0 (`:169`), and cannot use the timestamp, which is not authenticated. C2 needs one of: an upstream change adding `index` to `Frame`, or a wrapper built on `Consumer.make` as `i8-shaper.ts:65` does, which uses an `@internal` call and must be pinned and tested.

## Tests (brief item 5)

Most rows assert the behaviour they name, with exact boundaries (I06, I07, I10, G08 are good examples). Weak or missing:

| Row | Problem |
|---|---|
| I04 (`test.ts:58-66`) | Named "re-served older instance". The older instance never authenticates in the row. Add `authenticated(E1, …) === false` and the mark check (scratch A13 passes) |
| I14 (`test.ts:176-186`) | Asserts that a new object is empty. True of any class. Keep it, and say in the finding that the real evidence is the absence of module-level and stored state |
| I15 (`test.ts:188-198`) | Same inputs as I12 with a different constant |
| G10 (`test.ts:456-467`) | `mirror` is a `readonly` field, so the assertion cannot fail. I17 is the real mirror row |
| I09 | Exhaustion is tested with nothing accepted. No row has an accepted stream at exhaustion (F4) |
| I08 | Covers a timeout beside an accepted stream, not an authentication failure |

Spec cases with no row: same-epoch re-acceptance (F1); a probe ended by the transport (F2); the boundary at exactly 1500 ms (the code times out at `>= 1500`; I22 uses 1501 and I23 uses 1499); a start pruned by the window staying refused (only the cap variant, G14, is covered); `older_stream_only` with a newer candidate also present (F4); the track-count bound (F3).

## Scratch tests

File, not committed: `/private/tmp/claude-501/-Users-dukejones-work-IdentiKey-mjolnir/1a36b8bf-0268-4304-88d7-78c5a3cb1fdf/scratchpad/c1-adversarial.test.ts`. Epochs are `epoch(n) = n as 8 hex digits + "-0000-7000-8000-000000000000"`, scope as in the author's tests. "Fails" means the module does not do what the spec requires.

| ID | Input | Outcome |
|---|---|---|
| A01 | Accept `E1`, deliver audio groups 0…1000 step 20, `endInstance(E1)`, re-announce, re-accept `E1` at 21, replay group 0 | **Fails.** New tracker, `deliver` (F1) |
| A02 | 6 track failures at 2, bounce `E1`, 7 more at 7 | **Fails.** Six more `resubscribe` (F1) |
| A03 | Forged `E3`: `announce`, `subscribe(E3, i)`, `endInstance(E3)` repeated | **Fails.** 12 probes in 12 ms, real `E1` unreachable (F2) |
| A04 | Publisher `E1`, accept `E2`, 11 rejected forged probes, poll | **Fails.** State alternates `unavailable_retryable` and `superseded_by_another_instance` (F4) |
| A05 | Accept `E2`, announce `E1` and `E3`, `endInstance(E2)` | **Fails.** `older_stream_only` while `E3` is the next candidate (F4) |
| A06 | 200,000 distinct track names, one frame and one failure each | **Fails.** All retained, about 160 MB (F3) |
| A07 | Real `E1` timed out 8 times in a row | **Fails.** Waits 3 … 384 s, next 768 s (F5) |
| A08 | 200,000 random authenticated pairs per window, four windows | Passes. No pair delivered twice, at most 128 remembered |
| A09 | Zero window: group 10 index 0, then index 1 | Passes as written. Shows N1 |
| A10 | Bad frame reported at 1600 ms with and without `tick(1500)` first | Barred 60 s without, retried at 4.5 s with (L1) |
| A11 | 256 forged announcements, then the real one | Refused, same value as malformed, admitted after a clocked call (L2) |
| A12 | `authenticated(undefined, "bridge.tracks", 0)` on a fresh policy | **Fails.** Returns `true`, state `ready` (L3) |
| A13 | Accept `E2`, then older `E1` is announced and "authenticates", before and after `endInstance(E2)` | Passes. Never selected, mark stays `E2` |
| A14 | I8's delivery model on the C1 tracker, then slower retransmission | Passes at I8's parameters. Table above |

## What must change before C2

1. F1: clear track state only when the mark moves. Rows for the bounce and for the budget.
2. F2: a probe-ended event with backoff. `endInstance` stops retracting the announcement. Row.
3. F3: a cap on distinct track names per instance, no counters for unknown names. Row. Caps written into the spec.
4. F4: state as separate facts, a correct `older_stream_only`, and a result from `authenticated()` that names first acceptance.
5. F5: a 60 s cap on the backoff in `spec.md:22`, D2, ADR item 2 and the code. Row.
6. `spec.md:125`: the 120 ms window is provisional until C2's integrated run.

L1 to L5 and the test-row repairs can ride the same commit. N1 to N3 and the frame-index hook are C2 and C4 work and should be copied into those task boxes.
