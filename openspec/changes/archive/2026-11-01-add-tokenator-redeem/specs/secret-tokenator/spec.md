## MODIFIED Requirements

### Requirement: Copy-out is v1; thin proxy is the more secure pattern
<!-- base: 132e0851060451f669a0409c369905479034cb28 openspec/specs/secret-tokenator/spec.md -->

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
<!-- base: 132e0851060451f669a0409c369905479034cb28 openspec/specs/secret-tokenator/spec.md -->

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
<!-- base: 132e0851060451f669a0409c369905479034cb28 openspec/specs/secret-tokenator/spec.md -->

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
