# Tasks

- [x] Fresh advise after preparation — astra-arch-review accepts the 2026-11-04 prepared length-prefix JSON-to-proof contract in `design.md` and the `Holder proof fail-closed, nonce single-use` delta; see [return review](reviews/2026-11-04-advise-2.md).
- [x] Replace `signing_message/3` with the length-prefix frame in `design.md`
- [x] Make `egress/1` use the signed `method`, `resource`, decoded `body_b64`, and a nonempty `Idempotency-Key`. Do not read JSON `url` or a second method alias.
- [x] `mix test test/mjolnir/secrets/redeem_test.exs` covers the golden hex in `design.md` built without `signing_message/3`, a tamper of each new signed field and of the body, malformed JSON types and `body_b64`, copy-out versus egress method separation, the upstream method, URL, body, and idempotency header, nonce burn with no upstream call on a failed egress proof, rejection of the old four-line string, and the existing holder, commitment, expiry, and concurrency cases

## Owed by advise (2026-11-04, astra-arch-review)

- [x] Pin the JSON request-to-frame contract in design and delta: field names/types, required versus empty/default values, body transport bytes, digest derivation or decoding/comparison, method casing, and exact textual-field treatment. Include a concrete request and independently specified expected frame. See review finding 1.
- [x] Pin nonempty idempotency-key behavior and audience semantics; reconcile rejection versus ignoring of unsigned legacy method/URL aliases and identify the authoritative signed fields. See review finding 2.
- [x] Expand implementation verification to independent golden bytes, each new signed-field/body tamper, malformed fields, copy-out/egress separation, observed upstream method/URL/body/idempotency behavior, and nonce burning with no upstream call on failure; retain existing holder/commitment/expiry/concurrency checks. See review finding 3.

## Implementation verification (2026-11-04)

`mix test --no-compile test/mjolnir/secrets/redeem_test.exs`: **13 passed** (seed 545245). The literal golden frame, every signed-field/body tamper, malformed types/base64, endpoint separation, observed upstream request and idempotency behavior, nonce burn, and retained authorization/record/concurrency checks pass.

The plain acceptance command stalled while compiling the unchanged `Mjolnir.API.Router` and was interrupted. A process-local retry with signature inference disabled produced the compiled modules but timed out after 180 seconds while verifying that same router. Runtime tests above used those compiled modules; the normal compilation gate remains for the conductor to rerun. No compiler configuration or router implementation was edited.
