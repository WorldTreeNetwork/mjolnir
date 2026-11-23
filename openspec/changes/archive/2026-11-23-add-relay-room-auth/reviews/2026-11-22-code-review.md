READER: Claude Fable 5.2, fresh context, code review of 128a589..6f44fae
VERDICT: send-back (two must-fix)

# Security review: relay room-token mint (128a589..6f44fae)

Two must-fix defects, both in `scripts/relay-mint-key.sh`. The Elixir mint and the relay admission code are sound on tenant and room isolation; I found no cross-tenant or cross-room path. The weak areas are the rotation script's failure paths and the test coverage: most isolation properties are proven only by laptop prose.

What I ran:
- `mix test test/mjolnir/relay/ test/mjolnir/deploy/owner_mint_test.exs`: 8 passed.
- `cargo test --release --locked --lib`: 6 passed. I did not run the integration tests (`tests/webtransport.rs`, `tests/iroh_expiry.rs`).
- Scratch probes of mint failure modes, and of the rebuilt binary's `--check-keys` and `--write-mint-key`.
- Nothing was edited, committed, deployed or reached over ssh. The rotation script was read, not run.

## Must-fix before enabling on a production host

### M1. A failed confirmation leaves `relay-keys.json` at 0600 root, which the relay cannot read
- **Where:** `scripts/relay-mint-key.sh:257-266` (rotate) and `:306-314` (finish); `native/mjolnir_relay/src/main.rs:271-294`; `systemd/mjolnir-relay.service` (`User=mjolnir-relay`, only `CAP_NET_BIND_SERVICE`).
- **What is wrong:** `previous="$(mktemp)"` is 0600, `cp -f` keeps that mode, and the restore `mv -f "$previous" "$KEYS"` has no `chmod` after it. I reproduced the resulting 0600 file.
- **Failure:** a routine rotate or finish whose confirmation fails (relay down, or slower than 10 s) restores a file the relay user cannot open.
  - A running relay marks the keys invalid and refuses every new session on both transports.
  - A stopped relay fails to start.
  - A manual `chmod 0644` does not heal a running relay: the watcher sets `last = modified` before loading and never retries, and `chmod` does not change mtime.
- **Smaller race, same latch:** every publish does `mktemp` (0600), `mv`, then `chmod 0644`. A one-second poll landing between `mv` and `chmod` hits the same permanent `invalid`.
- **Related:** the temp files are in `/tmp`. Where that is tmpfs, `mv` into `/etc` is a copy, not the atomic rename D5/D9 assume.
- **Smallest fix:**
  - Create candidate and previous with `mktemp "$KEYS.XXXXXX"`, and `chmod 0644` before the rename.
  - In `spawn_key_watch`, do not latch `last` on a failed load.
- **Test gap:** the spec scenario "Confirmation fails" was never run; it is absent from `notes/laptop-rotation.md`.

### M2. After a failed or interrupted emergency, the default command re-trusts the stolen key
- **Where:** `scripts/relay-mint-key.sh:319-351`, default command at `:35`, rotate at `:242-281`.
- **What is wrong:** when emergency confirmation fails (or the script dies after line 333), `rotation.json` is already deleted, while `current.jwk` and `current.jwk.pub` are still the compromised key.
- **Attack path:** D10 says the operator "finishes the signer by re-running the script", and the runbook names no subcommand. A bare re-run is `rotate`. It finds no state, generates `next.jwk`, and publishes `{old stolen key, next}`. The stolen key is trusted again for at least ceiling + 60 s.
- **Until then:** the mint keeps returning 200 with tokens signed by a key the relay no longer trusts.
- **Smallest fix:** in `emergency`, remove `current.jwk` and `current.jwk.pub` at the moment the new set is published. The mint then returns 503, and a re-run takes the first-install path, which reuses `staged.jwk` and converges. Add the exact re-run command to the runbook.

## Should-fix

### S1. The public set is built from `.pub` sidecars, and the private and sidecar renames are two steps
- **Where:** `scripts/relay-mint-key.sh:97-127`, `:276-277`, `:338-339`, `:219-220`. The crash hook has no stop between the two renames.
- **Routine crash between 276 and 277:** `current.jwk` is the new key, `current.jwk.pub` the old one. A later `finish` passes its kid check and publishes the old public key only. The signer is then absent from the relay's set and every minted token is refused.
- **Emergency crash between 338 and 339:** the next `rotate` publishes the stolen key's public half and omits the real signer.
- **First-install crash between 219 and 220:** routine rotation is stuck on a missing sidecar.
- **Fix:** derive the public JWK from the private file at publish time, or at least assert the sidecar's `kid` and `x` equal the private file's.

### S2. A malformed `current.jwk` raises instead of returning 503, and can put the private key in the log
- **Where:** `lib/mjolnir/relay/mint.ex:137` and `:154`.
- **Reproduced:** a JWK with `d` but no `x` raises `FunctionClauseError`, and the formatted stacktrace contains the full map including `d`. A public-only JWK raises in `sign/3`, giving 500 where the contract says 503.
- **Likelihood:** low, since the script only writes whole keys, but the contract says the key is never logged.
- **Fix:** require binary `x` and `d` before `from_map`, and wrap load and sign in `try/rescue` returning 503 without inspecting the error.

### S3. The crash-resume branch does not re-derive the overlap
- **Where:** `scripts/relay-mint-key.sh:227-238`.
- **What is wrong:** after a stop at `state`, a later re-run renames the signer but keeps the original `not_before`. `finish` can then drop the old public key while tokens the old key signed are still unexpired, which D9 says never happens.
- **Also:** `set_hash` is written and never read, and `next.jwk`'s kid is not compared to the state.
- **Fix:** in that branch, check `sha256(KEYS)` and `keys.active` against `set_hash`, check the kid, and rewrite `not_before`.

### S4. Emergency swallows a failed restart
- **Where:** `scripts/relay-mint-key.sh:345` (`restart_relay || true`).
- **Failure:** with confirmation succeeded, the script exits 0 and prints "emergency signer is …" even if the relay never restarted, so sessions on stolen-key tokens stay up to their `exp`.
- **Fix:** record the restart status and exit non-zero.

### S5. The mint's env parser is not systemd's
- **Where:** `lib/mjolnir/relay/mint.ex:79-110`.
- **Reproduced:** `MJOLNIR_RELAY_TOKEN_MAX_TTL=60 ` (trailing space) makes the mint use 3600 while the relay loads 60, so a 3000 s token is issued and then refused. A quoted host is returned with its quotes.
- **Severity:** fails closed.
- **Fix:** trim values and strip one pair of quotes, or return 503 on an unparsable ceiling.

### S6. `confirm_active` can pass on two empty strings
- **Where:** `scripts/relay-mint-key.sh:137-154`.
- **What is wrong:** it runs inside `if`, so `set -e` is off. If `sha256_file` fails, `want` is empty, and a missing `keys.active` is also empty.
- **Fix:** `[[ -n "$want" ]] || return 1`.

### S7. Default token life of 300 s
See "Handoff and the default token life" below.

## Tests: refusals with no test that would fail if the check were removed

Elixir:
- **Participant segment.** `test/mjolnir/relay/mint_test.exs:70-77` varies only `room`. Deleting `segment(participant)` keeps the suite green.
- **Route.** There is no router test at all. Untested: the `principal_kind != :user` clause, `Cache-Control: no-store`, and that `x-owner-id` and body `owner_id` are ignored.
- **Token shape.** No test decodes a minted token, so adding `aud` or dropping `kid`, `jti` or `iat` would pass. The Rust fixture is a hand-made spike token, not `Mint.sign` output.
- **Key checks.** Only file mode 0640 is tested. Missing `current.jwk`, wrong uid, a group-writable directory and a key with no `kid` are untested.
- **Ceiling.** A ceiling below 300, and a `ttl` above a lowered ceiling, are untested.
- **Log line.** Nothing asserts the token is absent (the tasks admit this).

Relay:
- **Room isolation.** No automated test uses a room-rooted token. Cross-room read, cross-participant publish and announcement isolation are untested on both transports. `tests/webtransport.rs` uses `**` at `t/<owner>`.
- **In-band token.** `a_second_in_band_token_is_refused…` asserts moq-net's `unsupported`, not our refusal. The `web_grant` line is unreachable in production and has only its unit assertion.
- **Loader.** Private key in the set, empty set and duplicate kid have no crate test. I confirmed by hand that the binary refuses all three.

Script:
- No test in the repo. Untested: routine confirmation failure, the between-renames crash points, emergency followed by a re-run.

Ticked boxes whose proof is only prose: C5/S5 principals, C5 response shape and `no-store`, S8, the segment rule through the plug, C3, C3/M3, C1, C8, C6.

The S8 Iroh evidence is "connected and received no frames in the window", which is absence of delivery, not an observed refusal. S8 also records that `alice/track` was not published separately, so half of the "Own track" scenario did not run.

## Handoff and the default token life

`notes/h-handoff.md` measured a hole: the first publisher stops, a second starts, and the subscriber gets nothing more on either transport.

- **What was not measured:** the hypothesis as written, where the second session opens before the first drops. The box is ticked on a different experiment.
- **In practice:** the relay closes every session at `exp`. With the 300 s default, each participant reconnects every five minutes, and at each reconnect every other participant silently loses that person's media. It returns only when the subscriber itself resubscribes, which without client support is its own reconnect up to 300 s later. A guest cannot mint, so a guest's call ends at 300 s.
- **Smallest sound change:** make the default the ceiling (`clamp_ttl(nil, ceiling)` returns `ceiling`), and update D12, the spec's "default life SHALL be 300" and the first mint test.
- **Cost:** a handed-out token lives up to 60 minutes instead of 5. There is no kick either way, and only the owner can mint, so the short default was bounding little.
- **What it does not fix:** a call still hits a wall at 60 minutes. State in the contract that resubscribe-on-announce is a precondition for calls longer than one token. Return to a short default only after `call-client` shows it on both transports.

## Notes

- **`--write-mint-key`** (`main.rs:113-126`) applies 0600 only on creation; I confirmed an existing 0644 file stays 0644. The script is safe because the directory is 0700, but `create_new` or an `fchmod` would make it unconditional. There is no fsync on keys, the public set or `rotation.json`.
- **Spec deviations to fix at fold:**
  - Empty, `.` and `..` segments return 404 at the router, not the 400 the spec requires.
  - Capability and ceremony principals get 401 or never reach the route, not 403.
- **`profile`** (`lib.rs:101-129`) does not refuse an `iat` in the future, so the relay's lifetime cap binds only honest signers.
- **`root_allowed`** does not restrict room-segment characters; only the mint does.
- **Stale text:**
  - `lib.rs:67-71` is an empty `if`.
  - The comment at `lib.rs:510-511` is out of date.
  - The footer of `notes/laptop-rotation.md` still says the user mint, acceptance and handoff "were not run", contradicting `tasks.md`.
- **No mint rate limit** (deferred to `mjolnir-rurh.4`); each call is authenticated and cheap.
- **Deploy guard** (`scripts/relay-deploy-remote.sh:99-111`) does leave the running binary and unit untouched. Before it runs, the script re-modes the conf files, reinstalls helper scripts and may copy a certificate, all harmless.

## Builder claims checked

True:
- **Owner source.** Owner comes only from the verified `sub`; no header or body reaches `Mint.issue`. Reserved subs are rejected upstream, and operator, sites and capability principals cannot mint even if the route's kind check were removed.
- **Segment rule.** It is whole-string `\A…\z`, and Plug decodes after splitting, so `%2F` arrives as `a/b` and is refused.
- **`ttl`.** A string, float, boolean, null, 0, negative, bignum or above-ceiling value is 400.
- **Token shape.** A decoded token has header `alg`, `kid`, `typ` and exactly `root`, `publish[]`, `subscribe[]`, `iat`, `exp`, `jti`, with no `aud` and a 22-character `jti`. This matches the pinned `wire.rs`.
- **Key handling.** The key is read and mode-checked per mint. A key written by `--write-mint-key` is accepted by the mint.
- **Logging.** The success log has no token. Plug.Logger logs the path only.
- **CSRF.** No CORS headers, and the cookie is `SameSite=Lax`.
- **Loader.** It refuses a private key, no `kid`, a duplicate `kid`, a non-EdDSA/ES256 algorithm and an empty set.
- **`--write-mint-key`.** It prints public material only.
- **Relay admission.** Expiry is carried into Iroh authorizations. The session root is always the token root, not the dialed path. The Iroh path is logged without its query. `mjolnir-nopublish` is unreachable from any token root.
- **Lock.** The `flock` is sound and covers all three commands.
- **Emergency.** The function itself never restores the old set.

False or overstated:
- **Test name.** "mints a 300 second token and ignores the header owner" passes no header.
- **Crash recovery.** "After each stop the signer was still in the public set, and a rerun recovered" holds for the four injected points only; the rename pairs are uninjected, and one breaks `finish` (S1).
- **C6 / H-handoff.** Ticked, but the measurement is a hole, not the make-before-break the hypothesis states.
- **C7.** Described as the in-band refusal test; it proves moq-net does not take in-band tokens, not that our decider refuses them.
- **Emergency recovery.** D10 and the runbook imply a failed emergency is finished by re-running the script; a bare re-run undoes it (M2).
- **Confirmation failure.** D9's "restore the previous set" is described as safe; as built it locks the relay out of its key file (M1).

Relevant paths:
- `/Users/dukejones/work/IdentiKey/mjolnir/scripts/relay-mint-key.sh`
- `/Users/dukejones/work/IdentiKey/mjolnir/scripts/relay-deploy-remote.sh`
- `/Users/dukejones/work/IdentiKey/mjolnir/systemd/mjolnir-relay.service`
- `/Users/dukejones/work/IdentiKey/mjolnir/lib/mjolnir/relay/mint.ex`
- `/Users/dukejones/work/IdentiKey/mjolnir/lib/mjolnir/api/router.ex` (route at 239-275)
- `/Users/dukejones/work/IdentiKey/mjolnir/lib/mjolnir/deploy/owner.ex`
- `/Users/dukejones/work/IdentiKey/mjolnir/native/mjolnir_relay/src/lib.rs`
- `/Users/dukejones/work/IdentiKey/mjolnir/native/mjolnir_relay/src/main.rs`
- `/Users/dukejones/work/IdentiKey/mjolnir/native/mjolnir_relay/src/iroh_sessions.rs`
- `/Users/dukejones/work/IdentiKey/mjolnir/native/mjolnir_relay/tests/webtransport.rs`
- `/Users/dukejones/work/IdentiKey/mjolnir/test/mjolnir/relay/mint_test.exs`
- `/Users/dukejones/work/IdentiKey/mjolnir/openspec/changes/add-relay-room-auth/`
