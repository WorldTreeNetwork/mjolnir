## ADDED Requirements

### Requirement: Foreign secret stays in opaque store

A foreign secret (GitHub PAT, API key, or equivalent) SHALL be stored
only as `SecretStore` opaque bytes under
`_opaque/secrets/<secret_id>/`. The Biscuit that authorizes redeem
SHALL NOT contain those bytes. Guests SHALL NOT write this namespace.

#### Scenario: Deposit

- GIVEN an owner-authenticated request to store secret `github-pat-ci`
- WHEN it succeeds
- THEN `get_opaque("secrets", "github-pat-ci", "value")` returns the
  bytes
- AND no Biscuit minted for that id contains those bytes

#### Scenario: Guest cannot deposit

- GIVEN a guest presenting only a redeem Biscuit
- WHEN it attempts to write `_opaque/secrets/`
- THEN the write is denied

### Requirement: Redeem is on the existing API

Redeem SHALL be an HTTP POST on the host API already located by
`api_url` in `/etc/mjolnir/vm.json`. It SHALL NOT require a second
overlay port or a `tokenator_url`. The Biscuit plus holder proof
SHALL be the authorization for redeem; a VM-scope JWT SHALL NOT be
required of the using agent.

#### Scenario: Guest redeems via api_url

- GIVEN `api_url` in `/etc/mjolnir/vm.json`
- WHEN holder Z POSTs a valid Biscuit and holder proof to
  `/api/secrets/redeem`
- THEN the response body contains the secret bytes
- AND no other sidecar locator is required

#### Scenario: Extra overlay port proposed

- GIVEN a change that binds a new `host_api_ip` port for tokenator
  and adds `tokenator_url` to `vm.json`
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Holder proof fail-closed

Redeem SHALL verify a signature by the Biscuit-named public key
over a verifier nonce and the token identity, inject the holder
fact, then evaluate the Biscuit. Missing, wrong, or expired proof
SHALL return no secret.

#### Scenario: Wrong key

- GIVEN a Biscuit bound to Z
- WHEN a presenter signs as Q ≠ Z
- THEN redeem fails
- AND `get_opaque` is not returned to the presenter

#### Scenario: Bytes only

- GIVEN a valid Biscuit bound to Z
- WHEN it is POSTed without a holder signature
- THEN redeem fails

### Requirement: Secret not in logs

The host SHALL NOT write secret `value` bytes to logs, journald, or
API error bodies. It MAY log secret id, holder fingerprint, time,
and accept/reject.

#### Scenario: Failed redeem

- GIVEN a reject (bad proof or failed Datalog)
- WHEN logs are inspected
- THEN they do not contain the secret bytes

### Requirement: Recrypt data is not this vault

This capability SHALL apply to foreign secrets the host already
holds as opaque bytes. It SHALL NOT be the redeem path for
Recrypt-protected object ciphertext.

#### Scenario: Blob or PRE object proposed as opaque secret

- GIVEN a change that stores Recrypt-protected blob bytes in
  `_opaque/secrets/` so the tokenator can return them
- WHEN it is reviewed
- THEN it is rejected against this requirement
