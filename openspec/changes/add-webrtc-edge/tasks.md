# Tasks

PENDING until a fresh accept of this revision and of the reconciled `.12` contract. The 2026-11-26 build grant is already on the bead. Do not ask for it again. Do not deploy.

- [ ] Fresh advise of this contract and ADR 0020.
- [ ] After `.12` K0–K1 and this accept: admission and connection pool as design D1–D4, table-tested with `Mint.issue` open and protected tokens and a separately signed wide root. Dial counter zero on every refusal, including `/admit`.
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

- [ ] Fresh independent review of corrected admission/setup/lifecycle contract.
- [ ] Implement and exercise every boundary/race regression added to design D8; report real media results separately from contract acceptance.

## Third review: remaining G2 consistency

Send-back: `reviews/2026-11-26-advise-3.md` (a1be084f).

- [ ] Reconcile proposal expiry journey and original expiry task with whole-token expiry; qualify catalog timeout by pre-expiry and apply D8 precedence throughout D2/D3/spec. Fresh gateway gates remain open.

- [ ] Separate timeout-before-expiry regression: candidate resources released, same-token incumbent continues; at exp all same-token legs stop. Verify D8 error precedence on every setup exit.
