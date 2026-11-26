# Spike: how the relay accepts a `kind` claim at the moq pin

Date 2026-11-26 (UTC), macOS aarch64, relay toolchain 1.95.0. moq `4a6f522`, iroh-live `747b1bd`.
Local harness only, dummy Ed25519 key per run. Tokens are minted by `claim/mint_fixtures.exs` with JOSE,
the way `Mjolnir.Relay.Mint` signs (EdDSA, `kid` header, compact JWS). Logs: `logs/claim-offline.log`
and `logs/claim-live.log`, with tokens redacted.

## Verdicts

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| C1 | Today's production verifier refuses a token carrying a top-level `kind` claim, whatever its value | **proven** | offline: every `kind=…` row is `refuse(BadToken)` from `mjolnir_relay::assess`. Live: production `spawn_web_decider` answers `refused: unauthorized` for `kind=open` and for `kind=protected` |
| C2 | The same verifier still admits today's token (no `kind`) | **proven** | offline `no_kind` ADMIT; live `held` on the production decider |
| C3 | Route (b) admits `kind` absent, `open` or `protected`, and reports the kind | **proven** | offline ADMIT `Protected` / `Open` / `Protected`. Live: a `kind=open` publisher and reader on the route (b) relay, 25 frames (475 bytes) received; `protected` and no-kind sessions held; decider log `kind=Open` / `kind=Protected` |
| C4 | Route (b) refuses every other `kind` value | **proven** | `"OPEN"`, `"open "`, `1`, `null`, `["open"]` each refused `Kind(…)` |
| C5 | Route (b) keeps moq-auth's strictness for everything else | **proven** | another unknown claim (`foo`) refused by moq-auth's own `Claims` decoder, with or without `kind`. A repeated `kind`, a repeated `root` and an array payload are refused. A tampered payload is `InvalidSignature`. HS256 is refused (alg differs from the key's) |
| C6 | Time is controlled through signature verification and the relay profile | **proven** | under a kio `Manual` clock installed on the runtime, route (b) admits `kind=open` at `t0+599` and refuses at `t0+600` (`exp <= now`, as moq-auth `validate_times`). The production verifier rows were read at the same manual time (2025 tokens, so the host clock would refuse them all) |
| C7 | (a) forms the pinned decoder already tolerates | **proven, and rejected as the route** | `sub` as a string, `iss` as a string, and a custom protected-header parameter `kind` are all ADMITTED by the production verifier, which drops them. `sub` as an object is refused, by jsonwebtoken's own claim validation, not by moq-auth |
| C8 | Route (b) adds no crate to the relay graph | **proven for the spike lockfile** | `jsonwebtoken 11.1.0` and `rind-jsonwebtoken` were already in the relay's `Cargo.lock` through moq-auth. The spike's lock diff adds no package for them |
| — | Iroh admission with the claim | **not run** | `TokenPolicy::decide` calls the same `assess`, so the swap is one call site. The live Iroh leg is owed in `tasks.md` |
| — | Chromium WebTransport with the claim | **not run** | owed in `tasks.md` (compatibility) |
| — | Differential test of route (b) against moq-auth's shared corpus | **not run** | owed in `tasks.md` |

## What route (b) is

`claim.rs` in `rust/`. The relay stops calling `KeySet::verify` for room tokens and verifies the JWT itself:
it looks the key up by `kid` (the key loader already requires one), checks the header `alg` against the key,
checks that the key verifies and has no scope, verifies the signature with `jsonwebtoken::decode` using the
`Validation` moq-auth builds and the rind crypto provider moq-auth installs, reads the payload as an object
with no repeated member, removes `kind`, and hands everything else to `moq_auth::Claims`'s own strict
decoder, which still refuses any other unknown claim. Then it checks `exp`/`nbf`, then the relay `profile`,
the path and `grant_from`, unchanged. moq-auth is not patched. It no longer verifies the signature of a room
token: that is the cost.

## Why not (a) or (c)

- (a) is real. Today's relay already admits a token whose `sub` or `iss` string, or a header parameter,
  says "open". But none of those is a dedicated claim, and the owner chose a dedicated claim. `sub` and
  `iss` are registered claims with other meanings. A header parameter is outside the claim set that every
  moq verifier models. And an old reader admits such a token while ignoring the kind, so nothing forces
  readers to be upgraded first.
- (c), a carried moq-auth patch, would work. It is a vendored crate with the same `[patch]` lines in every
  consumer, carried on every pin move, and its field is too Mjolnir-specific to go upstream. See
  `../notes/claim-option.md`.
