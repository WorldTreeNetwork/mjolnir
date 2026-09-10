# secret-tokenator

What is built. Folded from
[`add-secret-tokenator`](../../changes/archive/2026-09-10-add-secret-tokenator/proposal.md)
on 2026-09-10. Decisions live in
[`docs/decisions/0008-secret-tokenator.md`](../../../docs/decisions/0008-secret-tokenator.md).

Fold-now SHALLs only (Fable 2026-09-10 fold guidance). Unimplemented
HTTP / NIF / mint / hop SHALLs wait on later changes and are **not**
living truth:
`add-biscuit-runtime` (real Blake3 NIF / authority key),
`add-tokenator-redeem` (challenge + POST handler; fourth Auth branch
before `localhost_bypass?`; nonce store; copy-out bytes),
`add-capability-mint` (deposit + mint; `meta` owner fingerprint),
`add-capability-hop` (signed block per hop).

## Purpose

Foreign secrets (GitHub PAT, API keys) live in opaque store with a
salted Blake3 commitment. Redeem is holder-bound, in the BEAM, on
existing `api_url`. No new overlay port. Copy-out is v1; thin proxy
is the more secure pattern. Recrypt PRE is not this vault.

## Requirements

### Requirement: Vault is opaque; commitment is salted Blake3

A foreign secret (GitHub PAT, API key, or equivalent) SHALL be stored
as `SecretStore.put_opaque("secrets", secret_id, "value", bytes)`.
`secret_id` SHALL be path-safe (no `/`, `..`, NUL). Guests SHALL NOT
write this namespace. Gordian envelopes are out of v1.

The public commitment SHALL be
`Blake3("mjolnir/secret-commit/v1" || salt || secret)` with `salt`
32 CSPRNG bytes. Salt MAY travel with the token. The secret bytes
SHALL NOT. An unsalted hash of the secret SHALL NOT appear on the
wire, in the Biscuit, or in logs. When Gordian envelopes are added
later, elision of a secret assertion SHALL be salted the same way.

Blake3 SHALL be real Blake3. `Sites.Crypto.blake3_hash/1` (SHA-256
stub as of 2026-08-26) SHALL NOT be used for this commitment or for
holder fingerprints. Holder fingerprints SHALL be auth-challenge v1
§5 (`Blake3(dcbor({alg,key}))`), not `IdentiKey.fingerprint/1`.

#### Scenario: Unsalted hash proposed

- GIVEN a change that puts `Blake3(secret)` (no salt) on the token
  or in an elided digest
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: SHA-256 stub used as Blake3

- GIVEN a mint or redeem path that calls `Sites.Crypto.blake3_hash/1`
  while that function is SHA-256
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Copy-out is v1; thin proxy is the more secure pattern

v1 SHALL offer copy-out (return `{value, salt}` to the named holder).
The more secure pattern SHALL be a thin proxy agent that is the
holder, redeems, and makes the upstream call so fat agents never
copy-out. v1 SHALL NOT require that proxy. A design that forbids
copy-out in v1 SHALL be rejected. Copy-out into a guest SHALL stay
in process memory or tmpfs and SHALL NOT be written to the
virtio-fs rootfs.

#### Scenario: Proxy-only v1 proposed

- GIVEN a change that forbids copy-out so every consumer must be a
  proxy VM
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Redeem is on the existing API, narrow Auth branch

Redeem SHALL be `POST {api_url}/api/secrets/redeem`. It SHALL NOT
require a second overlay port or a `tokenator_url`. Authorization
SHALL be Biscuit plus holder proof via a dedicated Auth plug
branch that confers redeem (and challenge) only. Those paths SHALL
NOT be listed in `@skip_auth_paths`. A VM-scope JWT SHALL NOT be
required of the using agent.

#### Scenario: Skip-auth redeem proposed

- GIVEN a change that adds `/api/secrets/redeem` to
  `@skip_auth_paths` in `Mjolnir.API.Auth`
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: Extra overlay port proposed

- GIVEN a change that binds a new `host_api_ip` port for tokenator
  and adds `tokenator_url` to `vm.json`
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Holder proof fail-closed, nonce single-use

Redeem SHALL verify a signature by the Biscuit-named public key
over a verifier nonce and the token identity, inject
`holder(<fingerprint>)`, then evaluate the Biscuit. Missing, wrong,
expired, or **reused** nonce SHALL return no secret.

### Requirement: Secret not in logs

The host SHALL NOT write secret bytes to logs, journald,
or API error bodies. It MAY log secret id, holder fingerprint,
time, and accept/reject.

### Requirement: Recrypt data is not this vault

This capability SHALL apply to foreign secrets stored as opaque
bytes with a salted Blake3 commitment. It SHALL NOT be the redeem
path for Recrypt-protected object ciphertext.

#### Scenario: Blob or PRE object proposed as this vault

- GIVEN a change that stores Recrypt-protected blob bytes in
  `_opaque/secrets/` so the tokenator can return them
- WHEN it is reviewed
- THEN it is rejected against this requirement
