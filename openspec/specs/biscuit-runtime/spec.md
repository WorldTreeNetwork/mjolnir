# biscuit-runtime

What is built. Seeded by
[`add-biscuit-runtime`](../../changes/archive/2026-09-26-add-biscuit-runtime/proposal.md)
on 2026-09-26 (bead `mjolnir-axsb.1.3`). Durable mint root folded from
[`add-biscuit-authority`](../../changes/archive/2026-11-01-add-biscuit-authority/proposal.md)
on 2026-11-01 (bead `mjolnir-reki.1`). The redeem profile this
runtime serves is ADR
[`0008`](../../../docs/decisions/0008-secret-tokenator.md); the wire
format is `identikey-capability-v1`, whose holder/hop/redeem SHALLs
live in identikey-protocol and are deliberately **not** copied here.

## Purpose

One Ed25519-rooted Biscuit mint/verify path and one real Blake3 for
the whole host. Protocol mint/verify is
[`identikey-capability`](https://crates.io/crates/identikey-capability)
0.1 (`identikey-capability-v1`). `native/mjolnir_biscuit` is a thin
face: JSON CLI, `COMMIT_DOMAIN = "mjolnir/secret-commit/v1"`, BEAM
`System.cmd` from `Mjolnir.Biscuit` — the same shape as `mjolnir-b3`,
not the rustler `:blake3` NIF. No vsock, no HTTP, no second
biscuit-auth mint path.

Holder fingerprints are the identikey-auth v1 §5 dCBOR map, which
commits to the algorithm; `IdentiKey.fingerprint/1` (raw pubkey
Blake3) is a different namespace and is not interchangeable. Secret
commitments are salted and domain-separated so an unsalted
`Blake3(secret)` is never a valid commitment.

## Requirements

### Requirement: Host mints and verifies Ed25519-rooted Biscuits

The host SHALL mint and verify Biscuits via `identikey-capability`
(Ed25519 authority, `biscuit-auth` 6 underneath). Serialize/parse SHALL round-trip. A
tampered authority block SHALL fail parse. Appending
`check if holder($fp), $fp == "<fp>"` SHALL succeed authorization
only when the verifier injects a matching `holder("<fp>")` fact.
Missing holder SHALL fail. This crate SHALL NOT expose HTTP.

#### Scenario: Mint round-trip

- GIVEN a fresh Ed25519 `KeyPair`
- WHEN the host mints a Biscuit and serializes it
- THEN `Biscuit::from` with the root public key succeeds

#### Scenario: Holder check is fail-closed

- GIVEN a token with `check if holder($fp), $fp == "<fp>"`
- WHEN the authorizer injects `holder("<fp>")` and allows the
  declared right
- THEN authorization succeeds
- WHEN that holder fact is omitted
- THEN authorization fails

#### Scenario: Tamper is rejected

- GIVEN serialized Biscuit bytes
- WHEN an authority byte is flipped
- THEN parse fails

### Requirement: Blake3 and holder fingerprints are protocol-correct

`blake3_hash(<<>>)` SHALL equal the official empty vector
`AF1349B9F5F9A1A6A0404DEA36DCC9499BCB25C9ADC112B7CC9A93CAE41F3262`.
Holder fingerprint of an Ed25519 public key SHALL equal
identikey-auth v1 §5 (`Blake3(dcbor({"alg","key"}))`), not
`IdentiKey.fingerprint/1`. Secret commitment SHALL be
`Blake3("mjolnir/secret-commit/v1" || salt || secret)` and SHALL NOT
be unsalted `Blake3(secret)`.

#### Scenario: Empty Blake3 vector

- GIVEN the empty byte string
- WHEN `blake3_hash` runs
- THEN the digest is the official 32-byte empty vector

#### Scenario: Holder fp is algorithm-committing

- GIVEN a 32-byte Ed25519 public key
- WHEN holder fingerprint is computed
- THEN it matches identikey-auth `ClassicalPublicKey::fingerprint()`
- AND it differs from Blake3 of the raw 32 bytes

#### Scenario: Commitment is domain-separated

- GIVEN salt and secret
- WHEN commitment is computed
- THEN it is 32 bytes
- AND it is not equal to `Blake3(secret)`

### Requirement: Mint root is durable

The host SHALL mint production Biscuits with one Ed25519 root that survives process restart. The private key SHALL live in one file, mode `0600`, outside `btrfs_root`, default `/var/lib/mjolnir/biscuit-root`. The file body SHALL be 64 lowercase hex characters and an optional trailing newline. An operator SHALL provision that file. The host SHALL NOT create it, overwrite it, or repair its mode. A missing file, a malformed body, a mode other than `0600`, an unreadable file, or a path inside `btrfs_root` or the per-VM LUKS escrow directory SHALL fail closed and SHALL NOT generate a replacement root. The private key SHALL NOT be supplied by an environment variable, SHALL NOT appear in subprocess argv, and SHALL NOT appear in exception text or subprocess diagnostics.

`Mjolnir.Biscuit.authority/0` SHALL be the production load. It SHALL cache the key in the BEAM. `mint_production/2` SHALL use that cache. `mint/3` SHALL remain an explicit-key helper and SHALL NOT load the host root. Application start SHALL publish the public half as `biscuit_public_hex` before the HTTP server accepts redeem. When `MJOLNIR_BISCUIT_PUBLIC_HEX` is set and disagrees with the file, boot SHALL fail closed. When it is unset, the verifier SHALL be the public half of the file. The production CLI request SHALL travel on stdin.

#### Scenario: Two mints share a public key

- GIVEN a configured durable mint root
- WHEN the host mints two production Biscuits
- THEN both verify with the same public hex
- AND that hex is `biscuit_public_hex`

#### Scenario: Restart reloads the same file

- GIVEN a token minted from the durable root
- WHEN a new process discards the cached key and loads the same file
- THEN the token verifies with the reloaded public key
- AND a new production mint uses that same public key

#### Scenario: Missing root fails closed

- GIVEN no durable mint root
- WHEN production mint runs
- THEN it returns an error
- AND it does not persist a newly generated root

#### Scenario: Bad file fails closed

- GIVEN a root file that is malformed, unreadable, or not mode `0600`
- WHEN the host loads the authority
- THEN load fails closed
- AND the file is left unchanged

#### Scenario: Configured public hex must match

- GIVEN a root file and a `MJOLNIR_BISCUIT_PUBLIC_HEX` that is not its public half
- WHEN the host boots
- THEN boot fails closed

#### Scenario: Unset public override derives the verifier

- GIVEN a valid root file and no `MJOLNIR_BISCUIT_PUBLIC_HEX`
- WHEN the host boots
- THEN `biscuit_public_hex` is the public half of that file

#### Scenario: Private key stays off argv

- GIVEN a production mint
- WHEN the host invokes `mjolnir-biscuit`
- THEN the private key is on stdin and not in argv
- AND a failing invocation does not include the private key in the error
