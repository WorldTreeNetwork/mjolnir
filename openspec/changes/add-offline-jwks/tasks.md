# Tasks

- [x] Persist last-known JWKS under `/var/lib/mjolnir/auth` (`0600`, not under `btrfs_root`)
- [x] Boot verifies unexpired hosted JWTs from cache when the issuer is down
- [x] Unknown `kid` is rejected
- [x] Opportunistic refresh when the issuer is reachable; overlapping keys both verify
- [x] Tests: reboot-with-issuer-down, stale cache, overlapping kids, empty cache fail-closed
- [x] Advise (architecture-adjacent auth) — accepted by astra-arch-review (Astra/Codex; author Grok), [review 4](reviews/2026-09-24-advise-4.md). Historical Fable 5.1 attempt was infra-red (Claude credits).

## Owed from Astra advise — 2026-09-24

Review: [send-back by astra-arch-review](reviews/2026-09-24-advise.md). These amendments belong to `mjolnir-22ff.1`; the banner remains PENDING.

- [x] R1: Define executable retention/retirement and revocation behavior, including `{A,B}` → `{B}` and restart; reconcile the skipped numeric window without inventing a TTL.
- [x] R2: Bind persisted trust to issuer and effective JWKS source; specify mismatch rejection and test old-authority keys claiming the new issuer.
- [x] R3: Specify validated, atomic cache publication and failure behavior for malformed/empty/conflicting keys, corrupt cache, permissions, and disk I/O; prove last-known-good survives restart.
- [x] R4: Name the Joken strategy integration seam, persisted merged state, bounded background fetch/retry behavior, and recovery tests after empty offline start.
- [x] R5: Add the bootstrap entry point and seeding/failure scenarios; cover btrfs path exclusion, issuer-disabled/empty-cache states, and negative signature/issuer/expiry verification.
- [x] Fresh advise after preparation — astra-arch-review accepted the reconciled Decision 7 + R9 contract; hashes in [review 4](reviews/2026-09-24-advise-4.md).
- [x] Fresh independent advise after R1–R5 are reconciled; accepted by astra-arch-review in [review 4](reviews/2026-09-24-advise-4.md). Historical Fable attempt retained above.

## Owed from Astra re-advise — 2026-09-24

Review: [second send-back by astra-arch-review](reviews/2026-09-24-advise-2.md). These amendments remain on `mjolnir-22ff.1`; both fresh-advise markers above remain open and the banner remains PENDING.

- [x] R6: Reconcile issuer-set retirement with additive merging and the proposal/steer retention wording; specify and test `{A}` → `{A,B}` → `{B}` in memory and after successful persistence/restart. Amended after advise-2: last validated issuer document replaces the set (not a union); proposal overlap wording superseded; `{A}` → `{A,B}` → `{B}` scenario added.
- [x] R7: Specify executable operator trust withdrawal for disk and the running signer table, including restart or live invalidation, in-flight refresh, final-key/empty-JWKS behavior, and how an offline operator seed becomes active; test the chosen procedure. Amended after advise-2: v1 procedure is stop → delete cache → start with issuer unreachable; empty JWKS does not clear cache; operator seed is next start.
- [x] R8: Reconcile active versus persisted signer sets when persistence fails; specify and test addition and retirement before/after restart, degraded-durability reporting, and recovery from trust restored by an older disk snapshot. Amended after advise-2: unknown-kid uses the active set; failed persist of add/retire scenarios added.

## Owed from Astra third advise — 2026-09-24

Review: [third send-back by astra-arch-review](reviews/2026-09-24-advise-3.md). Decision 7 resolves the architecture choices; one acceptance-scenario reconciliation remains on `mjolnir-22ff.1`. Both fresh-advise markers remain open; ACTIVE BUILD is unchanged.

- [x] R9: Align the legacy unknown-kid scenario with absence from the active issuer-bound set (or explicitly establish disk-only boot), and qualify retirement across restart on successful persistence of `{B}` before restarting offline. Preserve the failed-persist scenarios as complementary cases; do not reopen the replacement or degraded-durability policy. Amended after advise-3: unknown-kid GIVEN is active-set absence; retirement-across-restart requires successful persist of `{B}` then offline restart.

## Worker verification — 2026-10-15

The two requested test files pass: **17 tests, 0 failures**. The sandbox refuses
Bandit's listener with `:eperm` before the exact acceptance command reaches tests
(retried once). The same files were run without starting the application listener:

```sh
MIX_ENV=test mix run --no-start -e 'for app <- Application.spec(:mjolnir, :applications), do: Application.ensure_all_started(app); {:ok, _} = Mjolnir.StateStore.start_link([]); Mix.Task.run("test", ["--no-start", "test/mjolnir/auth/jwks_strategy_test.exs", "test/mjolnir/auth/jwks_cache_test.exs"])'
```

The worker packet explicitly supersedes the design's failed-persist behavior:
a failed persist preserves **both** the previous active set and previous disk
file. Tests cover failed additions and retirements under that packet contract.

Conductor re-ran the acceptance command on the host (Bandit can bind here):

```sh
mix test test/mjolnir/auth/jwks_strategy_test.exs test/mjolnir/auth/jwks_cache_test.exs
```

**17 tests, 0 failures** (seed 924557). Expected log lines (`JWKS cache unavailable`, `JWKS refresh kept last good set`) are not failures.
