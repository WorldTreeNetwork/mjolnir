## ADDED Requirements

### Requirement: Host mints and verifies Ed25519-rooted Biscuits

The host SHALL mint and verify Biscuits with `biscuit-auth` 6.0 using
an Ed25519 authority key. Serialize/parse SHALL round-trip. A
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
