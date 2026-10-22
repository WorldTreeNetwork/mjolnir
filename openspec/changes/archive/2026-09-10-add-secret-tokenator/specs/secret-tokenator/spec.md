## ADDED Requirements

### Requirement: Vault is opaque; commitment is salted Blake3

A foreign secret (GitHub PAT, API key, or equivalent) SHALL be stored
as `SecretStore.put_opaque("secrets", secret_id, "value", bytes)`
with `meta` holding owner fingerprint, salt, and commitment.
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

#### Scenario: Deposit

- GIVEN an owner-authenticated request to store secret `github-pat-ci`
- WHEN it succeeds
- THEN `get_opaque("secrets", "github-pat-ci", "value")` returns the
  bytes
- AND `meta` contains a 32-byte salt and a 32-byte commitment
- AND no Biscuit minted for that id contains those bytes

#### Scenario: Guest cannot deposit

- GIVEN a guest presenting only a redeem Biscuit
- WHEN it attempts to write `_opaque/secrets/`
- THEN the write is denied

#### Scenario: Copy-out matches the token

- GIVEN salt S and commitment C on the token
- WHEN the tokenator returns `{value: V, salt: S}`
- AND `Blake3("mjolnir/secret-commit/v1" || S || V) == C`
- THEN V is the secret that token committed to

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

#### Scenario: Fat agent copy-out

- GIVEN holder Z on a general-purpose VM
- WHEN redeem succeeds
- THEN Z receives `{value, salt}`
- AND a later snapshot of that VM does not contain those bytes on
  the virtio-fs rootfs unless Z wrote them there in violation

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

#### Scenario: Guest redeems via api_url

- GIVEN `api_url` in `/etc/mjolnir/vm.json`
- WHEN holder Z POSTs a valid Biscuit and holder proof
- THEN the response contains `{value, salt}`
- AND no other sidecar locator is required

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

#### Scenario: Wrong key

- GIVEN a Biscuit bound to Z
- WHEN a presenter signs as Q ≠ Z
- THEN redeem fails
- AND the secret bytes are not returned

#### Scenario: Bytes only

- GIVEN a valid Biscuit bound to Z
- WHEN it is POSTed without a holder signature
- THEN redeem fails

#### Scenario: Reused nonce

- GIVEN a challenge nonce already consumed in a redeem attempt
- WHEN it is presented again before `exp`
- THEN redeem fails
- AND no secret is returned

### Requirement: Secret not in logs

The host SHALL NOT write secret bytes to logs, journald,
or API error bodies. It MAY log secret id, holder fingerprint,
time, and accept/reject.

#### Scenario: Failed redeem

- GIVEN a reject (bad proof or failed Datalog)
- WHEN logs are inspected
- THEN they do not contain the secret bytes

### Requirement: Recrypt data is not this vault

This capability SHALL apply to foreign secrets stored as opaque
bytes with a salted Blake3 commitment. It SHALL NOT be the redeem
path for Recrypt-protected object ciphertext.

#### Scenario: Blob or PRE object proposed as this vault

- GIVEN a change that stores Recrypt-protected blob bytes in
  `_opaque/secrets/` so the tokenator can return them
- WHEN it is reviewed
- THEN it is rejected against this requirement
