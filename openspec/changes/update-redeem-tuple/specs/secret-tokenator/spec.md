## MODIFIED Requirements

### Requirement: Holder proof fail-closed, nonce single-use
<!-- base: a3a18fc4ef34c30a9e54b7fd6da386d54d43e6d5 openspec/specs/secret-tokenator/spec.md -->

Redeem SHALL verify a signature by the Biscuit-named public key over one private length-prefix frame. The frame domain SHALL be the bytes `mjolnir/redeem/v1\0`. Each field SHALL be a big-endian uint32 length followed by that many bytes, in this order: biscuit base64, the verifier nonce, audience, method, resource, body digest, secret id, idempotency key. The nonce SHALL be 64 lowercase hex characters. Audience SHALL be non-empty UTF-8 and SHALL be an opaque label: the verifier SHALL NOT compare it to a host, a configured identity, or the resource. Method and resource SHALL be the exact JSON strings, with no case folding and no trimming. The body digest SHALL be the 32 raw bytes of Blake3 over the bytes decoded from JSON string `body_b64`. A missing or empty `body_b64` SHALL mean an empty body. The verifier SHALL compute that digest and SHALL ignore any client-supplied digest field. Malformed `body_b64` SHALL fail the proof. Copy-out SHALL use the Blake3 of an empty body. A missing or empty `idempotency_key` SHALL frame an empty field and SHALL add no header. A nonempty `idempotency_key` SHALL be sent on egress as the header `Idempotency-Key` with that exact value, and this handler SHALL NOT deduplicate on it. Every framed JSON field, `body_b64`, `public_key`, and `signature` SHALL be a JSON string; a number, object, array, or null SHALL fail the proof. `public_key` and `signature` SHALL NOT be framed. The old newline string `mjolnir/redeem/v1`, nonce, biscuit base64, and secret id SHALL NOT verify.

Redeem SHALL inject `holder(<fingerprint>)`, then evaluate the Biscuit. The operation SHALL be `redeem` for the named secret id. Copy-out SHALL accept only method `REDEEM` and a resource equal to that secret id. Egress SHALL take its upstream method and URL from the signed `method` and `resource`, and SHALL forward the decoded `body_b64` bytes. JSON keys `url` and any method alias other than `method` SHALL NOT be read: their presence SHALL NOT reject the proof and SHALL NOT change the call. A URL whose host is outside the configured allow list SHALL still fail after the signature check, and that failure SHALL NOT call upstream. A wrong signer, a token with no holder check, a different resource or operation, or a change to any signed field SHALL return no secret. A nonce that is not 64 lowercase hex SHALL NOT be consumed. A well-formed nonce SHALL be consumed before the remaining proof runs. A failed proof after that SHALL burn the nonce, and a retry SHALL need a new challenge. The nonce SHALL be single-use and stored only in memory for 60 seconds. Missing, wrong, expired, or reused nonce SHALL return no secret. Concurrent consumers of one nonce SHALL have one success and the rest failure. A process restart SHALL invalidate outstanding nonces.

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

#### Scenario: Old newline tuple returns no secret

- GIVEN a fresh nonce and a signature over `mjolnir/redeem/v1\n<nonce>\n<biscuit-base64>\n<secret_id>`
- WHEN redeem runs
- THEN no secret is returned
- AND that nonce cannot be used again

#### Scenario: Egress uses the signed request

- GIVEN a fresh nonce and a signature over the length-prefix frame whose `method` and `resource` name an allow-listed URL
- AND `body_b64` decodes to the bytes whose Blake3 is in that frame
- AND `idempotency_key` is nonempty
- WHEN egress runs
- THEN the upstream call uses that method, that URL, those body bytes, and header `Idempotency-Key` equal to that key
- AND a JSON `url` or a second method alias does not change the call and does not reject it
- AND a client-supplied digest field does not change the framed digest

#### Scenario: Copy-out and egress do not accept each other's method

- GIVEN a fresh nonce and a valid signature whose method is `POST`
- WHEN that proof is posted to copy-out
- THEN no secret is returned
- AND the nonce is burned
- GIVEN a fresh nonce and a valid signature whose method is `REDEEM` and whose resource equals the secret id
- WHEN that proof is posted to egress
- THEN egress does not call upstream
