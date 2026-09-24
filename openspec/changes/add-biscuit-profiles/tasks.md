# Tasks

- [ ] Holder-bound profile: session public key authorized at login; request signature required; stolen token fails
- [ ] Explicit bearer profile: shorter/narrower; mode bit distinct
- [ ] Verifier cannot downgrade holder-bound to bearer
- [ ] Vectors: signature requirement, stolen token, attenuation, edge/audience binding, explicit bearer, expiry
- [ ] Cite `mjolnir-axsb.1.3` as the only mint/verify; no second runtime
- [x] Advise — astra-arch-review, other-family reader for Grok; accept in `reviews/2026-09-24-advise-3.md` (Fable infra-red)

## Owed from architecture advise 2026-09-24

Review: `reviews/2026-09-24-advise.md` — `astra-arch-review`, send-back.

- [x] Define/reference the versioned per-request holder proof: signed capability identity, intended request/body, audience, freshness/replay ownership and rejection rules; add substitution, tamper, stale, and replay vector cases (finding 1)
- [x] Pin issuer-authenticated profile mode and immutable holder restrictions; reject unknown/conflicting modes and token-supplied holder facts in every block; specify chain/check enforcement and downgrade/attenuation vector cases (finding 2)
- [x] Define the shared-runtime/profile/Auth integration contract: trusted issuer, subject XID, edge/audience, effective authority/expiry, credential precedence and fail-closed behavior, enforceable bearer ceilings, audit events, and corresponding vector cases (finding 3)
- [x] Resolve the `0012-direct-edge-auth` ADR citation or name its prerequisite; obtain fresh independent advise on the amended contract, preserving PENDING until activation
- [x] Fresh advise after preparation — astra-arch-review; Decisions 7–8 and amended delta accepted in `reviews/2026-09-24-advise-3.md`, with contract hashes recorded

## Owed from architecture re-advise 2026-09-24

Review: `reviews/2026-09-24-advise-2.md` — `astra-arch-review`, send-back.

- [x] Finish login-proof encoding/token-and-body hash preimages, request-target query binding, nonce issuance/scope/validity/atomic consumption/state-loss rules, and adversarial vector obligations; explicitly gate any deferred wire contract on a named prerequisite (re-review finding 1)
- [x] Define trusted adapter inputs and request/resource-bound authorization output, issuer-authenticated subject, all-checks/expiry enforcement, rejection behavior, and foreign-root/expiry/resource-attenuation vector obligations (re-review finding 2)
