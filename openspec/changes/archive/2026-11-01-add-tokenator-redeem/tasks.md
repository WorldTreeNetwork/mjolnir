# Tasks

- [x] Success body returns `value_b64` and `salt_b64` from stored `value` and `meta`, and `secret_commit(salt, value)` matches `commitment_hex`
- [x] A fresh nonce with a valid holder proof returns the secret; wrong signer, holderless token, wrong resource or operation, and tampered signed fields return none and burn the nonce
- [x] A reused, expired, restarted, or concurrently replayed nonce returns no secret
- [x] Redeem succeeds with no VM-scope JWT, operator shortcuts off, and ceremony does not admit another route
- [x] Missing, malformed, or legacy value-only records, and every error body and log, contain neither the secret nor the salt; egress does not gain `salt_b64` and does not call upstream on those failures
- [x] On fold, the living purpose no longer lists redeem as unbuilt

## Owed from advise (2026-10-31, astra-arch-review)

- [x] Pin the salt source and its association with the committed value, 32-byte validation, provisioning/fixture boundary, missing/malformed/legacy-record failure behavior, and preservation of shared egress behavior; add commitment-match and no-secret-on-failure acceptance. See reviews/2026-10-31-advise.md, finding 1. Do not implement deposit or mint here.
- [x] Specify focused real-proof router verification with operator shortcuts disabled and no JWT: wrong signer, holderless token, wrong resource/operation, signed-field tampering, expired/restarted nonces, concurrent replay, failed-proof nonce consumption, and no general API authority. See reviews/2026-10-31-advise.md, finding 2.
- [x] Fresh advise after preparation: amended contract accepted by astra-arch-review in reviews/2026-10-31-advise-2.md; this fresh review supersedes the prior send-back.

## Out of scope

- A second redeem route
- Removing `/api/egress` from the ceremony branch
- Deposit, hop, and the mint-root home
