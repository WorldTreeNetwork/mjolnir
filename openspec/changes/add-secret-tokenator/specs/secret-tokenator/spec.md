## ADDED Requirements

### Requirement: Vault is an owner-signed Gordian envelope

A foreign secret (GitHub PAT, API key, or equivalent) SHALL be stored
as an assertion on a Gordian envelope signed by the owner's
Identikey, via `SecretStore.put(identikey_fp, "secrets/<secret_id>",
envelope)`. It SHALL NOT be stored as `put_opaque` raw bytes. At
rest the secret assertion is present. Guests SHALL NOT write this
keyspace. `secret_id` SHALL be path-safe (no `/`, `..`, NUL).

#### Scenario: Deposit

- GIVEN an owner-authenticated request to store secret `github-pat-ci`
- WHEN it succeeds
- THEN `SecretStore.get(fp, "secrets/github-pat-ci")` returns an
  envelope whose secret assertion is present
- AND no Biscuit minted for that id contains those bytes

#### Scenario: Guest cannot deposit

- GIVEN a guest presenting only a redeem Biscuit
- WHEN it attempts to write `secrets/` in any Identikey keyspace
- THEN the write is denied

### Requirement: In-flight envelope is elided; copy-out is verifiable

What travels with the Biscuit SHALL be the envelope with the secret
assertion **elided** (digest remains). Copy-out SHALL return the
secret bytes. The recipient SHALL be able to verify that value
against the elided digest the envelope committed to. A value that
does not match SHALL be rejected by the recipient as not the
token's secret.

#### Scenario: Copy-out matches the token

- GIVEN an elided envelope whose digest is D
- WHEN the tokenator returns value V
- AND Blake3/envelope digest of V equals D
- THEN V is the secret that envelope committed to

#### Scenario: Wrong bytes

- GIVEN the same elided envelope
- WHEN a presenter is given some other V'
- THEN verification against D fails

### Requirement: Copy-out is v1; thin proxy is the more secure pattern

v1 SHALL offer copy-out (return secret bytes to the named holder).
The more secure pattern SHALL be a thin proxy agent that is the
holder, redeems, and makes the upstream call so fat agents never
copy-out. v1 SHALL NOT require that proxy. A design that forbids
copy-out in v1 SHALL be rejected. Copy-out into a guest SHALL stay
in process memory or tmpfs and SHALL NOT be written to the
virtio-fs rootfs.

#### Scenario: Fat agent copy-out

- GIVEN holder Z on a general-purpose VM
- WHEN redeem succeeds
- THEN Z receives the secret bytes
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
- THEN the response contains the secret bytes
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
- AND the secret assertion is not returned

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

The host SHALL NOT write secret assertion bytes to logs, journald,
or API error bodies. It MAY log secret id, holder fingerprint,
time, and accept/reject.

#### Scenario: Failed redeem

- GIVEN a reject (bad proof or failed Datalog)
- WHEN logs are inspected
- THEN they do not contain the secret bytes

### Requirement: Recrypt data is not this vault

This capability SHALL apply to foreign secrets stored as elided
assertions on owner-signed envelopes. It SHALL NOT be the redeem
path for Recrypt-protected object ciphertext.

#### Scenario: Blob or PRE object proposed as this vault

- GIVEN a change that stores Recrypt-protected blob bytes in
  `secrets/` so the tokenator can return them
- WHEN it is reviewed
- THEN it is rejected against this requirement
