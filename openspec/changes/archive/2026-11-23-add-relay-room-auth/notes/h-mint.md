# H-mint

Result: confirmed, 2026-11-22, on this Mac.

An Elixir JOSE EdDSA token verifies under `KeySet::verify` at moq `4a6f522`.

- Signer: `JOSE.JWT.sign` with `%{"alg" => "EdDSA", "kid" => kid}` on an OKP Ed25519 key. The compact form includes header `typ: JWT`. moq-auth accepts that header.
- Claims: `root`, `publish` as `["p/**"]`, `subscribe` as `["**"]`, integer `exp` and `iat`, `jti`. No `aud`.
- Public JWK needs `alg: EdDSA`. `use: sig` was present and did not stop verification.
- Fixture: `native/mjolnir_relay/tests/fixtures/elixir-eddsa.json`. Test: `elixir_eddsa_token_verifies`. It failed first because the public JWK had no `alg` (`missing field alg`). After `alg` was set, the test passed.

The mint uses this signer. It does not add `aud`.
