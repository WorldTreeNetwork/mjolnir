# add-biscuit-runtime

> **ACTIVE BUILD**

Bead `mjolnir-axsb.1.3`. Activated 2026-09-24 (human: activate axsb first).

**Rigor:** change

## Why

Login profiles (`add-biscuit-profiles`) and later tokenator redeem
need one Ed25519-rooted Biscuit mint/verify and real Blake3. There is
no `biscuit-auth` in this tree. Sites Blake3 already goes through
`mjolnir-b3`; holder fingerprints must be auth-challenge v1 §5, not
`IdentiKey.fingerprint/1` (raw pubkey). A second runtime would fork
`identikey-capability-v1`.

## What

- Workspace crate `native/mjolnir_biscuit` (`biscuit-auth` 6, `blake3` 1).
  No vsock. No HTTP.
- BEAM face is a binary + `System.cmd` (same shape as `mjolnir-b3`),
  not the rustler `:blake3` NIF.
- Mint an authority block, round-trip `to_vec` / `Biscuit::from`,
  append `check if holder($fp), $fp == "…"`, authorize with injected
  `holder` fact, reject tamper and missing holder.
- `blake3_hash(<<>>)` matches the official empty vector.
- Holder fp of an Ed25519 pubkey equals
  `identikey_auth::ClassicalPublicKey::fingerprint()` on the same 32
  bytes.
- Secret commitment is
  `Blake3("mjolnir/secret-commit/v1" || salt || secret)` (32 bytes).
- Existing SecretStore directory names unchanged. No `/api/secrets/*`.

## Impact

- Capabilities: ADDED `biscuit-runtime`
- ADRs: none (format is `identikey-capability-v1`; profiles stay
  `add-biscuit-profiles`)

## User journey & surfaces

No new UI because this is a host library the API and `mj` will call
later. No HTTP.

- **Working (after act)** — Elixir mints a holder-checked Biscuit,
  verifies it, rejects a widened/tampered one; Blake3 empty vector
  and §5 fps pass in `mix test`.
- **Empty** — no crate, no binary.
- **Failed (today)** — no `biscuit-auth`; Sites Blake3 is real via
  `mjolnir-b3`; holder fps are still a different namespace.
- **Off** — JWT login unchanged.

## Out of scope

- Holder-bound vs bearer login profiles — `add-biscuit-profiles`
- POST `/api/secrets/redeem` — `mjolnir-axsb.1.4`
- Deposit/mint CLI — `mjolnir-axsb.1.5`
- Third-party hop blocks — `mjolnir-axsb.1.6`
- Edge operational keys — `add-edge-op-keys`
- Direct challenge consume — `add-direct-challenge`
- identikey-core managed signer — `add-managed-challenge-responder`
- Gordian envelopes
- Replacing JWT for VM-exec (`mjolnir-k8y.5`)
