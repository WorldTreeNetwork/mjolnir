# C1 — transport-free reader policy

Location proposed for review: `clients/call-crypto/reader-policy.ts`, with only `reader-policy.test.ts` beside it. The design previously named no adapter directory. No browser app, crypto implementation, package scaffold, transport, timer, storage or deploy was added. Scope is the C1 policy module requested by the orchestrator; C2 wiring is not built.

Verification: Node 26 `node --test clients/call-crypto/reader-policy.test.ts`: **46 passed, 0 failed** (30 instance/lifecycle rows, 16 group/frame rows). Strict TypeScript check passes. All clock and authentication outcomes are explicit inputs; the module cannot authenticate ciphertext by itself. The caller must report actual crypto success and transport-frame identity, not public timestamps.

Test-first evidence:

- `logs/c1-red.log`: all 42 initial rows fail against an exported surface whose constructors throw C1-not-implemented, before the implementation.
- First implementation passed 41/42; the remaining test fixture uppercased an all-numeric UUID, which did not change it. The fixture now uses a hex letter. No parser relaxation was made.
- `logs/c1-refinement-red.log`: I27/I28 fail against the initial code: withdrawal/reannounce erased refusal/backoff, and announcement state had no bound. Both fixed before green.
- `logs/c1-withdraw-red.log`: I29 fails before separating announcement withdrawal from actual accepted-instance termination. Retraction alone must not stop accepted playback (withdraw is not retirement).
- `logs/c1-stale-red.log`: I30 fails before requiring the epoch on track-failure events; stale callbacks from a retired subscription must not spend the new instance's resubscribe budget.
- Final `logs/c1-green.log`: 46/46 pass. `logs/c1-types.log`: strict module typecheck exit 0.

## API and integration boundary

InstancePolicy owns one immutable profile/kid/label/opaque scope for one page. Announcements never advance its mark. `nextCandidate` selects; `subscribe` is called exactly when manifest subscription starts. `authenticated(epoch, semantic, now)` accepts only bridge.tracks and a live probe (or the accepted manifest stream). Candidate failure, timeout/backoff and accepted-track failure are separate events. `trackFailure(epoch, semantic, now)` returns a bounded same-generation resubscribe action, ignoring old-epoch callbacks. A transport end uses `endInstance`, whereas `withdraw` is only an announcement retract. Publisher self-watch/resume and the stated fast-clock replay limit are in the table.

GroupTracker receives **authenticated** group start and frame index; it holds no media and owns an opaque mirror identity token. C2 attaches its real local mirror to that lifetime. `track()` caches that state within an accepted generation. Same-group frames strictly above the saved index continue; 120ms media span is supplied in authenticated track units, zero for manifest/catalog. Earlier admitted frame indices cannot reopen. uint64 groups use bigint; frame indices are uint32.

Operational bounds for Fable review: at most 256 active/refusal candidates per immutable label scope; at most 128 remembered group starts per track, with an irreversible eviction floor so dense starts cannot reopen evicted frames. Honest 20ms audio in I8 needed at most seven. These are memory/denial bounds, not availability guarantees. A relay can flood them just as it can withhold announcements. Old-instance cached marks/mirrors/budgets are released when a greater instance accepts; retained caller references are not mutated.

Remaining contract/integration concerns: I6 is still inconclusive and C4 issue mjolnir-rurh.9.2 is open. Public pinned decrypted Frame omits index; C2 needs an index-preserving hook (I8). No crypto/path-discovery-through-relay, bridge, invite UI, metadata parsing, real mirror wiring or browser rekey is claimed by these pure tests. The memory bounds should be included in the adapter contract during code review; they do not change the 12-probe or 6-resubscribe budgets.

## Regression table

| ID | Regression | Observed red | Final |
|---|---|---|---|
| I01 | announcement alone cannot move mark | initial 42-row baseline | PASS |
| I02 | candidates tried greatest first | initial 42-row baseline | PASS |
| I03 | forged greater authentication failure falls through | initial 42-row baseline | PASS |
| I04 | re-served older instance does not roll back | initial 42-row baseline | PASS |
| I05 | plaintext wrong label and wrong opaque refused | initial 42-row baseline | PASS |
| I06 | timeout retries after 3 seconds and counts budget | initial 42-row baseline | PASS |
| I07 | successive timeout doubles backoff | initial 42-row baseline | PASS |
| I08 | probing failure keeps accepted playback | initial 42-row baseline | PASS |
| I09 | twelve attempt rolling budget | initial 42-row baseline | PASS |
| I10 | authentication bars candidate for sixty seconds | initial 42-row baseline | PASS |
| I11 | noncanonical epochs rejected | initial 42-row baseline | PASS |
| I12 | ended selected instance keeps mark | initial 42-row baseline | PASS |
| I13 | second device supersedes publisher only after authentication | initial 42-row baseline | PASS |
| I14 | reload new page loses credential and mark | initial 42-row baseline | PASS |
| I15 | fast clock blocks honest lower until explicit page reset | initial 42-row baseline | PASS |
| I16 | recorded greater manifest supersedes after each resume | initial 42-row baseline | PASS |
| I17 | track failure keeps instance generation mark and mirror | initial 42-row baseline | PASS |
| I18 | six resubscriptions then unavailable | initial 42-row baseline | PASS |
| I19 | resubscription budget recovers after rolling minute | initial 42-row baseline | PASS |
| I20 | resubscription budget is per track | initial 42-row baseline | PASS |
| I21 | only manifest accepts instance | initial 42-row baseline | PASS |
| I22 | late frame after probe timeout cannot accept | initial 42-row baseline | PASS |
| I23 | timeout starts at subscription not announcement | initial 42-row baseline | PASS |
| I24 | invalid and backward policy clocks refused | initial 42-row baseline | PASS |
| I25 | immutable credential scope validation | initial 42-row baseline | PASS |
| I26 | accepted failure is not candidate rejection | initial 42-row baseline | PASS |
| I27 | withdrawal reannouncement cannot clear refusal or backoff | refinement red | PASS |
| I28 | announcement flood has bounded candidate memory | refinement red | PASS |
| I29 | retracting announcement does not stop accepted media | withdraw red | PASS |
| I30 | stale retired subscription failure cannot consume new epoch budget | stale-callback red | PASS |
| G01 | authentic first frame advances pair | initial 42-row baseline | PASS |
| G02 | higher authenticated group advances pair | initial 42-row baseline | PASS |
| G03 | equal group continues strictly above saved index | initial 42-row baseline | PASS |
| G04 | frame replay cannot reopen | initial 42-row baseline | PASS |
| G05 | manifest catalog zero window rejects older group | initial 42-row baseline | PASS |
| G06 | forged high frame never advances mark | initial 42-row baseline | PASS |
| G07 | media accepts unseen older start within 120ms | initial 42-row baseline | PASS |
| G08 | window boundary inclusive and older refused | initial 42-row baseline | PASS |
| G09 | late group frame index remembered independently | initial 42-row baseline | PASS |
| G10 | mirror identity survives equal group continuation | initial 42-row baseline | PASS |
| G11 | frame gap resumes at authenticated transport index | initial 42-row baseline | PASS |
| G12 | group identities keep uint64 precision | initial 42-row baseline | PASS |
| G13 | invalid nonce identities refused | initial 42-row baseline | PASS |
| G14 | dense starts have bounded replay memory | initial 42-row baseline | PASS |
| G15 | per instance and track marks do not mix | initial 42-row baseline | PASS |
| G16 | changing window cannot reset existing mark | initial 42-row baseline | PASS |
