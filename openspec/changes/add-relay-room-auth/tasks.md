# Tasks

Every refusal test is written first and seen to fail for the stated reason before the code that makes it pass.

- [x] Fresh advise after the `9e664a1` amendments. Second pass `reviews/2026-11-22-advise-2.md` accepted, with C1–C9 written into this change before implementation.
- [x] C4 / M1: Public owner function, no trim, lowercase `\A[0-9a-f]{64}\z`. Hex and base58 of the same bytes match. Uppercase hex, hex plus newline, padded base58, a 31-byte id, and a leading `1` are each refused. The header is not an input of `mint_owner/1`. A caller `sub` that is not an owner is 403 in the mint test.
- [ ] C5 / S5: User principal plus `relay:join`. Operator, sites, capability, and ceremony are each 403. Failing-first.
- [ ] C5: Body `ttl` edges are 400 in `mint_test.exs`, and the module response has the six keys. `Cache-Control: no-store` is set on the route's 200. It was not observed: the laptop `POST` returned 401 with no user token.
- [x] C2 / S6: Each mint reads `/etc/mjolnir-relay/relay.env` for enabled, host, and `MJOLNIR_RELAY_TOKEN_MAX_TTL`. 503 for missing key, bad mode, env missing, enabled not `true`, host unset. Mode check takes an injectable uid and path. `mint_test.exs` covers disabled, mode `0640`, a missing env file, and an unset host. The missing-file and unset-host test passed on the first run (`74b21e8`); the behavior was already in `Mint`.
- [x] M4: Default TTL 300 seconds. A ceiling clamp is in the mint. The test covers the 3600 ceiling.
- [x] S1: Publish `<participant>/**`, subscribe `**`, root `t/<owner>/<room>`.
- [x] S7 / H-mint: Cross-language fixture verifies. See `notes/h-mint.md`. The mint uses that JOSE shape. The log line is the `Logger.info` in `Mint.issue/5` and does not include the token. No test asserts the log text.
- [ ] C6 / H-handoff: Not run. The examples are built on the laptop (`target/release/examples`). No subscriber was driven across a publisher make-before-break, so there is no gap, `Restart`, or frame-loss number.
- [ ] C7: `spawn_decider` is in the library and `tests/webtransport.rs` calls it. The unit refusal is in `lib.rs` (`in-band token was admitted`, then the assertion passed, commit `105acf0`). No integration test opens a live session and sends a second token.
- [ ] S8: Failing-first, on the shipped decider, both transports: cross-participant `Q` and `Q/track`, exact `P` admitted, cross-room read from a session admitted for R, announcements list nothing from S.
- [ ] Segment rule, whole-string: empty, 65 characters, `.`, `..`, `%2F`, `%5C`, `*`, `%0A`, trailing newline. Each is 400 before a signature.
- [x] C3: `mjolnir-relay --check-keys`. Script checks algorithm and `kid` `\A[A-Za-z0-9_-]{1,128}\z` itself. `flock`. `rotation.json` owns step 5. First install confirms the public set before `current.jwk` exists. Relay down: non-zero, no `current.jwk`. Laptop: `notes/laptop-rotation.md`. A crash was not killed between every step.
- [x] C3 / M3: Two-key overlap, `finish`, and a live WebTransport hold across rotate ran on the laptop. No `kid` is refused by the loader unit test. Signing with a key absent from the confirmed set was not separately observed.
- [x] C1: Emergency revoke on the laptop did not restore the old set, restarted the relay, and a new session with the old token was refused. The live session was gone 1.37ms after shutdown was requested, inside a 15s drain. There was no `next.jwk` to delete, and the failed-confirmation branch was not driven.
- [ ] C8: Not run as a user mint. The laptop route returned 401. `wt-session hold` and `refuse` ran with `dev-key` tokens, not a controller mint. `iroh-publish` and `iroh-subscribe` were not driven. The journal was not grepped for a minted token.
- [x] C9: Mint rate limit recorded on `mjolnir-rurh.4`.

Out of scope stays in the proposal. Those lines are not tasks.
