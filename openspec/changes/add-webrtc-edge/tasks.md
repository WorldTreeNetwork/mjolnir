# Tasks

PENDING until a fresh accept of this revision and of the reconciled `.12` contract. The 2026-11-26 build grant is already on the bead. Do not ask for it again. Do not deploy.

- [x] Fresh advise of this contract and ADR 0020. Accepted at `7f9195cb2b5178071d507dc2b5ad44ea91a5f4cd`: `reviews/2026-11-26-advise-4.md` (contract only).
- [ ] After `.12` K0–K1 and this accept: admission and connection pool as design D1–D4. Local unit tests in `native/mjolnir_relay/src/edge.rs` cover mint-shaped open claims, protected and wide roots, zero dials on refusal including `/admit`, one dial for two legs, and the DELETE matrix. A disposable relay with coloured frames is not in this slice. Ubuntu binary still open.
- [ ] Two legs, one token, one connection; a second token does not share it. DELETE matrix: owner, repeat, other token, unknown id. Failed renewal leaves the old id. Expiry during catalog wait stops all same-token legs and preserves other-token legs.
- [ ] Coloured frames and fixture tone both ways on a disposable relay. Before expiry, codec miss and missing catalog return `409` with no registered id; expiry takes precedence as `403 bad_token`.
- [ ] Invalid verify-set reload refuses new admissions and leaves a live session until drain closes the relay connection.
- [ ] Ubuntu 24.04 build of this binary. Do not cite `claim8-linux.log` for it; that log is Arch x86_64.
- [ ] Handoff for `.15`: `/admit` response, status codes, `Location`, configured origin, DELETE with the admitting bearer. `RoomJoin` is not this binary.

## Out of scope

- `.14` roster. `.12` viewer path. Production flag. `.4` quotas. Safari and eight-PC proofs.

## Fresh independent re-review of 6abb5065

Send-back: `reviews/2026-11-26-advise-2.md`. Keep the fresh gate open; no activation or product work from this review.

- [ ] G1/G3: make /admit run operation/grant/expiry checks, define its room input and exact RoomClass grammar, and include key_file_trusted parity.
- [ ] G2: correct same-token expiry assertions; start the deadline before pool/dial; define timeout precedence, single-flight reservations, natural runner cleanup and finite DELETE tombstone retention.
- [ ] G4: require accepted video rather than mere m-line presence; cover canonical path decode/bounds and coordinate actual admission error mapping with the browser.

## Reconciliation after second review

- [x] Fresh independent review of corrected admission/setup/lifecycle contract. See `reviews/2026-11-26-advise-4.md`; implementation and media gates remain open.
- [ ] Implement and exercise every boundary/race regression added to design D8; report real media results separately from contract acceptance.

## Third review: remaining G2 consistency

Send-back: `reviews/2026-11-26-advise-3.md` (a1be084f).

- [ ] Reconcile proposal expiry journey and original expiry task with whole-token expiry; qualify catalog timeout by pre-expiry and apply D8 precedence throughout D2/D3/spec. Fresh gateway gates remain open.

- [ ] Separate timeout-before-expiry regression: candidate resources released, same-token incumbent continues; at exp all same-token legs stop. Verify D8 error precedence on every setup exit.

## Independent CODE review of 4169315 — send-back

Review: `reviews/2026-11-27-code-review-4169315.md`. Contract acceptance remains intact; these are implementation obligations on `.13`. No `.15` activation, closure, fold or deploy.

- [ ] R1: own every acquired reservation through cancellation/runner completion; watch relay closure per generation, clean the gateway session/ref/link maps, and verify a different token stays alive.
- [ ] R2: preserve min(exp, start+5s) through acquisition, dial and negotiation; precise expiry timer, every-exit expiry precedence, relay-close race and final pre-201 generation/expiry check; prove candidate timeout preserves incumbents.
- [ ] R3: tie queued/delivered HTTP answer to pending-session ownership; dropped body and failed socket delivery cancel only that candidate and release its hold.
- [ ] R4: reserve notified followers against a connection generation; test rejected/cancelled leader, cancelled waiter, last release and new acquire with controlled interleavings.
- [ ] R5: validate the raw URI broadcast before Axum decoding; one decode and identical grant/moq path; real Router encoded separator/double-decode/bounds regressions.
- [ ] R6: preserve typed setup errors; real absent broadcast with valid viewer is 409 not_started, expired viewer is 403 bad_token, relay death is 503 before expiry.
- [ ] R7: configured origin allowlist with same-origin default and max-age 600; /admit no-store and ordered JSON error envelope; remove global concurrent dial-counter assertions.
- [ ] R8: finalize DELETE/expiry/completion through digest-only exp+30s tombstones; foreign bearer 403, owner repeat 204, periodic reaping without another DELETE.
- [ ] R9: configure the relay token ceiling; separate drain from key health; reload cannot reopen drain; exercise live invalid reload, recovery and emergency teardown.
- [ ] R10: apply the recorded default ingest rate cap before actual WHIP accept; verify TIAS/REMB and over-cap termination while preserving adopted keyframe trial defaults.
- [ ] Consolidate production-path regressions instead of treating fabricated-answer attach tests as runtime coverage; cfg-gate mock-only helpers, redact Checked Debug, verify valid foreign CA and hostname rejection.
- [ ] Re-run repaired binary with recorded hash and real Mint-issued media/refusal/expiry/isolation cases; repeat early/late tone checks on the repaired hash (current a8e6b9b7 diagnostics pass both); preserve the outstanding Ubuntu 24.04 gate.
