# Tasks

Every refusal test is written first and seen to fail for the stated reason before the code that makes it pass.

- [ ] M1: Owner is the caller's verified `sub` via `Owner.resolve/2` (header ignored). Canonical base58, or a legacy 64-hex `sub` re-encoded to base58. Anything else is 403 before a signature. Failing-first test: a user who sends another owner's id in `x-owner-id` is rooted at their own `sub`, never the other tenant.
- [ ] M3: Unique `kid` on every key and in every token. Rotation publishes `{current, next}`, confirms `keys.active`, then switches the signer, and restores the previous set if confirmation fails. First install replaces the fixture key. Tests: a two-key set admits a token from each key; a token with no `kid` against a two-key set is refused; during a scripted rotation the signer is never a key absent from the confirmed set.
- [ ] M4: Default mint TTL is 300 seconds. Caller `ttl` is honored up to the relay maximum and refused above it. Routine rotation and emergency revoke are the two procedures in the design.
- [ ] S1: Mint emits publish `["<participant>/**"]` and subscribe `["**"]` under root `t/<owner>/<room>`.
- [ ] S4: Documented in the proposal. No code for delegated invites.
- [ ] S5: Route requires `principal_kind == :user` in addition to `relay:join`. Operator is 403. Failing-first.
- [ ] S6: Mode-check and read `current.jwk` on every mint. 503 when the key is missing, the mode is wrong, the relay is disabled, or the host is unset. No signature in those cases.
- [ ] S7: Cross-language fixture. A token signed by the Elixir mint verifies under `KeySet::verify` at the pinned revision. `kid`, EdDSA, integer `exp` and `iat`, `jti`, no `aud`. Mint log line has `sub`, owner, room, participant, `jti`, `exp`, and not the token. This is H-mint.
- [ ] S8 refusals, each failing-first, on both transports where a session is involved: cross-participant publish of `Q` and of `Q/track`; exact `P` admitted; cross-room read from a session admitted for R (every spelling that transport uses, and its announcements list nothing from S); segment rule below.
- [ ] Segment rule, whole-string match: empty, 65 characters, `.`, `..`, `%2F`, `%5C`, `*`, `%0A`, and a trailing newline. Each is 400 before a signature.
- [ ] Iroh expiry and the in-band refusal already landed in `105acf0`. Do not reopen them except to keep the relay suite green.
- [ ] Fresh advise after these amendments.

Out of scope stays in the proposal. Those lines are not tasks.
