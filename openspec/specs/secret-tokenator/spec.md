# secret-tokenator

What is built. Folded from
[`add-secret-tokenator`](../../changes/archive/2026-09-10-add-secret-tokenator/proposal.md)
on 2026-09-10. Decisions live in
[`docs/decisions/0008-secret-tokenator.md`](../../../docs/decisions/0008-secret-tokenator.md).

Fold-now SHALLs only (Fable 2026-09-10 fold guidance). Redeem folded
from
[`add-tokenator-redeem`](../../changes/archive/2026-11-01-add-tokenator-redeem/proposal.md)
on 2026-11-01 (bead `mjolnir-reki.3`). Mint folded from
[`add-capability-mint`](../../changes/archive/2026-11-01-add-capability-mint/proposal.md)
on 2026-11-01 (bead `mjolnir-reki.2`). Unimplemented NIF / hop
SHALLs wait on later changes and are **not** living truth:
`add-biscuit-runtime` (real Blake3 NIF / authority key),
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
The redeem success body SHALL be `{value_b64, salt_b64}` and SHALL NOT
carry the secret in an error body. The salt SHALL be the 32-byte salt
already stored with that secret. Redeem SHALL NOT invent a salt.

The pair SHALL already be two opaque objects:
`SecretStore.get_opaque("secrets", secret_id, "value")` and
`SecretStore.get_opaque("secrets", secret_id, "meta")`. This change
SHALL NOT write either object. Deposit and mint remain
`add-capability-mint`. A test MAY call `put_opaque` for both keys as
a fixture. `meta` SHALL be UTF-8 JSON. Redeem SHALL read `salt_b64`
and `commitment_hex` and SHALL ignore other keys. `salt_b64` SHALL
decode to exactly 32 bytes. `commitment_hex` SHALL be 64 lowercase
hex characters. Success SHALL require
`Mjolnir.Biscuit.secret_commit(salt, value)` to equal that
commitment. Missing `value`, missing `meta`, malformed JSON, a salt
that is not 32 bytes, a commitment that is not 32 bytes, or a
commitment that does not match SHALL return no secret and no salt.
A legacy object that has `value` and no `meta` SHALL fail the same
way. Redeem SHALL NOT log the value or the salt.

`prove/1` is shared with egress. Egress SHALL keep its current
response shape: upstream status and body, no `salt_b64`, and no
secret. A salt or commitment failure SHALL stop egress before the
upstream call.

The more secure pattern SHALL be a
thin proxy agent that is the holder, redeems, and makes the upstream
call so fat agents never copy-out. v1 SHALL NOT require that proxy. A
design that forbids copy-out in v1 SHALL be rejected. Copy-out into a
guest SHALL stay in process memory or tmpfs and SHALL NOT be written
to the virtio-fs rootfs. The host handler SHALL NOT write the secret
onto a guest rootfs.

#### Scenario: Proxy-only v1 proposed

- GIVEN a change that forbids copy-out so every consumer must be a
  proxy VM
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: Copy-out returns value and salt

- GIVEN a fixture that stored `value` and `meta` for one secret id
- AND `meta.salt_b64` is 32 bytes and `meta.commitment_hex` equals `secret_commit(salt, value)`
- WHEN `POST /api/secrets/redeem` succeeds for that id
- THEN the body contains `value_b64` and `salt_b64` for that stored pair
- AND the secret bytes are absent from the error body

#### Scenario: Missing or legacy record returns no secret

- GIVEN a secret id with `value` and no `meta`, or with `meta` whose salt or commitment does not match
- WHEN redeem or egress runs after a valid holder proof
- THEN no secret and no salt are returned
- AND egress does not call upstream

#### Scenario: Egress does not gain a salt field

- GIVEN a matching `value` and `meta` and a valid holder proof
- WHEN `POST /api/egress` succeeds
- THEN the body has the upstream status and body
- AND the body has no `salt_b64` and no secret bytes

### Requirement: Redeem is on the existing API, narrow Auth branch

Redeem SHALL be `POST {api_url}/api/secrets/redeem`, handled by
`Mjolnir.Secrets.Redeem`. It SHALL NOT require a second overlay port
or a `tokenator_url`. Authorization SHALL be the ceremony branch in
`Mjolnir.API.Auth`, checked before JWT, for
`/api/secrets/challenge`, `/api/secrets/redeem`, and `/api/egress`
only. That branch SHALL confer no scopes. Holder proof SHALL run in
the handler. Those paths SHALL NOT be listed in `@skip_auth_paths`.
A VM-scope JWT SHALL NOT be required of the using agent.

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

#### Scenario: Redeem without a VM-scope JWT

- GIVEN a valid holder proof and a fresh nonce
- AND operator shortcuts and localhost bypass are off
- WHEN the caller posts `/api/secrets/redeem` with no JWT
- THEN the ceremony branch admits the request
- AND the handler's proof decides whether the secret is returned

#### Scenario: Ceremony is not general API authority

- GIVEN a caller with no JWT and no operator credential
- WHEN they call an authenticated route other than challenge, redeem, or egress
- THEN the ceremony branch does not admit that route

### Requirement: Holder proof fail-closed, nonce single-use

Redeem SHALL verify a signature by the Biscuit-named public key over
the tuple `mjolnir/redeem/v1`, the verifier nonce, the biscuit
base64, and the secret id, joined by newlines. It SHALL inject
`holder(<fingerprint>)`, then evaluate the Biscuit. The operation
SHALL be `redeem` for the named secret id. A wrong signer, a token
with no holder check, a different resource or operation, or a change
to any signed field SHALL return no secret. The nonce SHALL be
consumed before that proof runs. A failed proof SHALL burn the nonce,
and a retry SHALL need a new challenge. The nonce SHALL be single-use
and stored only in memory for 60 seconds. Missing, wrong, expired, or
reused nonce SHALL return no secret. Concurrent consumers of one
nonce SHALL have one success and the rest failure. A process restart
SHALL invalidate outstanding nonces.

#### Scenario: Reused nonce returns no secret

- GIVEN a nonce that redeem has already consumed
- WHEN redeem is called again with a holder proof over that nonce
- THEN no secret is returned

#### Scenario: Failed proof burns the nonce

- GIVEN a fresh nonce and a proof with the wrong signer, a holderless token, the wrong resource or operation, or a tampered signed field
- WHEN redeem runs
- THEN no secret is returned
- AND that nonce cannot be used again

#### Scenario: Expired or restarted nonce returns no secret

- GIVEN a nonce older than 60 seconds, or a nonce issued before the nonce process restarted
- WHEN redeem runs
- THEN no secret is returned

#### Scenario: Concurrent replay returns one secret

- GIVEN one fresh nonce and two redeem calls with the same valid proof
- WHEN both run
- THEN at most one call returns the secret
- AND the other returns no secret

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

### Requirement: Deposit mints a holder-checked token

The host SHALL deposit a foreign secret through `Mjolnir.Secrets.Deposit.deposit/3`. The secret id SHALL be path-safe (no `/`, `\`, NUL, or `..`). The secret SHALL be a non-empty binary. The owner key SHALL be a 32-byte Ed25519 public key. The deposit SHALL store the secret only as `SecretStore.put_opaque("secrets", secret_id, "value", bytes)`.

It SHALL store opaque `meta` as UTF-8 JSON whose `salt_b64` is 32 CSPRNG bytes and whose `commitment_hex` is 64 lowercase hex characters of `Mjolnir.Biscuit.secret_commit(salt, secret)`. It SHALL store the owner fingerprint as opaque key `owner`, the lowercase hex of `Mjolnir.Biscuit.holder_fingerprint/1` on that public key. The fingerprint SHALL NOT be a Gordian envelope and SHALL NOT be required inside the JSON `meta`.

The deposit SHALL mint with `Mjolnir.Biscuit.mint_production(secret_id, "redeem")` and SHALL append a holder check for that fingerprint. The token SHALL NOT assert a holder fact, SHALL NOT contain the secret or the salt, and SHALL NOT carry a hop block. `mint/3` SHALL NOT be the production deposit path.

The deposit SHALL take the id by exclusive create of the `secrets/<id>` directory. If that create loses, or the directory already exists, the call SHALL return an error and SHALL NOT read, replace, or delete `value`, `meta`, `owner`, or any `.tmp` sibling already there. A separate existence check followed by writes SHALL NOT count as that reservation. There is no replace operation. An old token keeps naming the id it was minted for, and a later deposit SHALL NOT put a different secret under that id.

Success SHALL return the holder-checked token only after `value`, `meta`, and `owner` are published. A failure after this attempt won the directory SHALL delete only that directory, the objects this attempt wrote, and their `.tmp` siblings, and SHALL NOT return a token. If that cleanup itself fails, or the process dies, the leftover directory stays in place, no token is returned, and a later deposit SHALL NOT adopt or replace it. A refusal before the directory is created SHALL create nothing and SHALL preserve any directory that already exists. The host SHALL NOT log the secret bytes, and SHALL NOT include them in an error.

#### Scenario: Deposit stores the secret and the owner fingerprint

- GIVEN a path-safe secret id, a non-empty secret, and a 32-byte owner public key
- WHEN the host deposits
- THEN `value` is the secret
- AND `meta` commits that secret under the stored salt
- AND `owner` is the §5 fingerprint of that public key

#### Scenario: Authorization requires the injected holder

- GIVEN a token from that deposit
- WHEN the verifier injects the stored owner fingerprint
- THEN authorization of `redeem` on that secret id succeeds
- WHEN the verifier does not inject it
- THEN authorization fails

#### Scenario: Validation refusal writes nothing

- GIVEN an empty secret, a secret id that is not path-safe, or an owner key that is not 32 bytes
- WHEN deposit is attempted
- THEN it returns an error
- AND no directory is created for that id

#### Scenario: An existing id is preserved

- GIVEN a secret id whose directory already exists, including a partial one
- WHEN another deposit uses that id
- THEN it returns an error
- AND the existing objects are unchanged
- AND no token is returned

#### Scenario: One of two concurrent deposits wins

- GIVEN two deposits of the same new id
- WHEN both attempt the exclusive create
- THEN one succeeds
- AND the loser returns an error without replacing or deleting the winner's objects

#### Scenario: A failed publication returns no token

- GIVEN a reservation this attempt owns
- WHEN a later object write, the mint, or the holder append fails, and cleanup succeeds
- THEN no token is returned
- AND that attempt's directory is gone
- WHEN cleanup itself fails
- THEN no token is returned
- AND the leftover is not adopted by a later deposit
- AND the error does not contain the secret

#### Scenario: Token does not carry the secret

- GIVEN a deposited secret
- WHEN the minted token is decoded as text
- THEN the secret bytes are absent
