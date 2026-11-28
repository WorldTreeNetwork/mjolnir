# Tasks

Fresh advise of this text, then a green local `.13` slice, then the named-peer work. `.14` still blocks closing the node. The build grant is already recorded. Do not deploy.

- [x] Fresh advise. Accepted a1be084f by independent reader in `reviews/2026-11-26-advise-3.md`.
- [x] Module tests with a fake configured origin: bad status, real gateway `unexpected_root`, `room_not_open`, and comparator `kind_mismatch`, no `getUserMedia` before success. Invitation paths that are absolute URLs or contain `..` never fetch. `native/mjolnir_room` 11 tests.
- [x] Partial renew rolls back only the new generation. A late `getUserMedia` from the old generation does not attach. The old timer does not close the new PeerConnection. `teardown` DELETEs with the admitting bearer.
- [x] One Chromium page against the local gateway: notice before the prompt, coloured frames and tone on one named peer. `not_started` retry and WHIP `403` cleanup are covered by the module tests. Evidence: `reviews/2026-11-27-named-peer-slice.md`. The bead stays open.
- [ ] Do not check the bead done.

## Out of scope

- `.14`, Safari phone, three networks, eight PeerConnections, minting, TURN, E2EE.

## Fresh independent re-review of 6abb5065

Send-back: `reviews/2026-11-26-advise-2.md`. Keep the fresh gate open; no activation or product work from this review.

- [x] B1/B3: admit self publish and every named peer subscribe for immutable attempt inputs; reject expired-on-arrival admission before camera and cover late camera cleanup.
- [x] B2: retain incumbent through bounded publisher readiness; same-path announcement is not atomic (the pin announces inside accept); overlapping incumbent/candidate callbacks; candidate tracks stop when publisher setup fails.
- [ ] B4: reconcile actual gateway 403 translation with expected-root/kind journeys; distinguish comparator tests from real endpoint behavior.

## Reconciliation after second review

- [x] Fresh independent review of corrected admission/setup/lifecycle contract. Accepted a1be084f in `reviews/2026-11-26-advise-3.md`.
- [ ] Implement and exercise every boundary/race regression added to design D5; report real media results separately from contract acceptance.
