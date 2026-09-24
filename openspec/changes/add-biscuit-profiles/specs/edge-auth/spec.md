## ADDED Requirements

### Requirement: Login capabilities are holder-bound by default

An edge-issued login capability SHALL default to holder-bound: it
authorizes an ephemeral session public key whose fingerprint is
auth-challenge v1 §5, and a protected request SHALL prove possession
of that key. The token SHALL NOT assert a `holder` fact; the verifier
SHALL inject it from the request signature. Verification of a
holder-bound token without that signature SHALL fail. A verifier SHALL
NOT accept a holder-bound token as bearer.

#### Scenario: Stolen holder-bound token fails

- GIVEN a valid holder-bound login capability for session key `S`
- WHEN a caller presents the token bytes without a signature by `S`
- THEN the request is rejected

#### Scenario: Holder-bound cannot be verified as bearer

- GIVEN a holder-bound token
- WHEN a verifier that only implements bearer checks it
- THEN it is rejected
- AND the mode is unambiguous on the token

### Requirement: Bearer issuance is explicit

The edge MAY mint a bearer login capability only when issuance
explicitly requests bearer. A bearer token SHALL have shorter lifetime
and narrower authority than the default holder-bound token for the
same subject, and SHALL be distinguishable from holder-bound.

#### Scenario: Explicit bearer works until expiry

- GIVEN an explicitly issued bearer capability
- WHEN it is presented unexpired within its authority
- THEN it is accepted
- AND a holder-bound token is not required for that call

#### Scenario: Edge and audience binding

- GIVEN a capability minted for edge XID `E`
- WHEN it is presented to a different edge or audience
- THEN it is rejected

### Requirement: Holder proof binds this request

A holder-bound request SHALL include a session-key signature over
canonical dCBOR
`["mjolnir-login/v1", biscuit_hash, method, request_target,
body_hash, edge_xid, nonce, exp]` as specified in this change’s
design Decision 7. `biscuit_hash` SHALL be Blake3 of the exact
presented token bytes. `request_target` SHALL include the raw query
string when present. The nonce SHALL be edge-issued and consumed
atomically with accepting the effect. The edge SHALL reject wrong
key, different token bytes, altered body, query/method/path
substitution, wrong audience, stale or unknown nonce, concurrent
reuse, and post-restart replay of a lost nonce. The verifier SHALL
inject `holder(fp)` only after that proof succeeds. Failure SHALL
NOT fall back to bearer.

#### Scenario: Altered body fails

- GIVEN a valid holder-bound token and a proof over body hash `H1`
- WHEN the request body hashes to `H2`
- THEN the request is rejected

#### Scenario: Proof replay fails

- GIVEN a proof whose nonce was already accepted
- WHEN it is presented again
- THEN the request is rejected

#### Scenario: Query substitution fails

- GIVEN a proof over `GET /api/vms/:id/terminal?session=a`
- WHEN the request is `GET /api/vms/:id/terminal?session=b` with the
  same token and nonce still outstanding
- THEN the request is rejected

#### Scenario: Lost nonce store fails closed

- GIVEN a proof with an unexpired nonce
- WHEN the nonce store has been lost (restart without the record)
- THEN the request is rejected

### Requirement: Profile mode is issuer-authenticated

`login_mode` SHALL appear in the authority block as `"holder"` or
`"bearer"`. Absent, unknown, or conflicting modes SHALL reject.
Attenuation SHALL NOT remove holder checks or change mode.
Token-asserted `holder` facts in any block SHALL reject. A
bearer-only verifier SHALL reject `login_mode("holder")`.

#### Scenario: Appended bearer mode does not downgrade

- GIVEN a holder-bound token
- WHEN an attenuation block asserts `login_mode("bearer")` or a
  holder fact
- THEN verification fails

### Requirement: Biscuit credentials do not inherit JWT full scope

A presented `Authorization: Bearer biscuit:` value SHALL be
recognized before localhost bypass. Verified output SHALL be a one-shot allow/deny for **this** request
(subject XID, edge XID, mode, token expiry for audit). It SHALL NOT
be a reusable ambient scope. Adapter evaluation SHALL include
request facts (path/query resource ids). A token attenuated to one
resource SHALL deny a different resource. Deny SHALL NOT populate
claims or fall back to JWT or localhost. Sites `mjsk_` tokens stay first when
presented. Ambiguous credentials SHALL fail closed. Explicit bearer
issuance SHALL be strictly shorter-lived and narrower than the
holder policy for the same subject.

#### Scenario: Loopback does not widen a biscuit

- GIVEN a holder-bound biscuit with only `vms:read` presented from
  loopback
- WHEN the request requires `vms:stop`
- THEN it is denied
- AND localhost bypass is not applied to that credential

#### Scenario: Overbroad bearer is rejected at mint

- GIVEN an explicit bearer request whose lifetime or rights meet or
  exceed the holder policy
- WHEN the edge mints
- THEN mint fails

#### Scenario: Resource attenuation is not ambient

- GIVEN a holder-bound token attenuated to `vm=A`
- WHEN it is used on `vm=B` with a valid login proof
- THEN the request is denied

#### Scenario: Foreign root is denied

- GIVEN a biscuit whose mint root is not this edge’s operational
  delegated key
- WHEN it is presented
- THEN it is rejected

