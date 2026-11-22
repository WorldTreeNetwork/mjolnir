# Tasks

Every refusal test is written first and seen to fail for the stated reason before the code that makes it pass.

- [x] Fresh advise after the `9e664a1` amendments. Second pass `reviews/2026-11-22-advise-2.md` accepted, with C1–C9 written into this change before implementation.
- [ ] C4 / M1: Public owner function, no trim, lowercase `\A[0-9a-f]{64}\z`. Failing-first: another owner's header does not change the root. Hex and base58 of the same bytes match. Uppercase hex, hex plus newline, padded base58, a 31-byte id, and a non-canonical base58 spelling are each 403.
- [ ] C5 / S5: User principal plus `relay:join`. Operator, sites, capability, and ceremony are each 403. Failing-first.
- [ ] C5: Body `ttl` is a JSON integer. `0`, negative, above the ceiling, a string, and a float are 400 before a signature. Response keys `token`, `expires`, `root`, `publish`, `subscribe`, `relay_host`. `Cache-Control: no-store`.
- [ ] C2 / S6: Each mint reads `/etc/mjolnir-relay/relay.env` for enabled, host, and `MJOLNIR_RELAY_TOKEN_MAX_TTL`. 503 for missing key, bad mode, env missing, enabled not `true`, host unset. Mode check takes an injectable uid and path.
- [ ] M4: Default TTL 300 seconds, clamped to the ceiling from that file.
- [ ] S1: Publish `<participant>/**`, subscribe `**`, root `t/<owner>/<room>`.
- [ ] S7 / H-mint: Cross-language fixture before the route serves clients. `jti` is 22 base64url characters. Log line has no token.
- [ ] C6 / H-handoff: Both-transport test that a subscriber still receives across make-before-break. Record the result. Do not promise a seamless call. Resubscribe stays on `call-client`.
- [ ] C7: `spawn_decider` lives in the library. WebTransport tests call it. Integration test: an in-band second token leaves the session up and the grant unchanged.
- [ ] S8: Failing-first, on the shipped decider, both transports: cross-participant `Q` and `Q/track`, exact `P` admitted, cross-room read from a session admitted for R, announcements list nothing from S.
- [ ] Segment rule, whole-string: empty, 65 characters, `.`, `..`, `%2F`, `%5C`, `*`, `%0A`, trailing newline. Each is 400 before a signature.
- [ ] C3: `mjolnir-relay --check-keys`. Script checks algorithm and `kid` `\A[A-Za-z0-9_-]{1,128}\z` itself. `flock`. `rotation.json` owns step 5. First install confirms the public set before `current.jwk` exists. Relay down: non-zero, no `current.jwk`.
- [ ] C3 / M3: Two-key set admits each key. No `kid` against two keys is refused. Scripted rotation never signs with a key absent from the confirmed set. These run as root on the laptop.
- [ ] C1: Emergency revoke never restores the old set. Deletes `next.jwk` if present. Failed confirmation still restarts and exits non-zero. Test for the stolen-key path.
- [ ] C8: One-host acceptance, no browser: mint through the API, then `wt-session`, `iroh-publish`, and `iroh-subscribe`. Grep the relay journal for the token string.
- [ ] C9: Mint rate limit recorded on `mjolnir-rurh.4`.

Out of scope stays in the proposal. Those lines are not tasks.
