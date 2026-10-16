## ADDED Requirements

### Requirement: Direct identity proof is identikey-auth v1

Native direct authentication SHALL use `identikey-auth-challenge-v1`
Challenge/Response without modification. `Challenge.aud` SHALL be the
pinned edge stable XID. The exchange SHALL NOT require OAuth,
browser redirects, or identikey-core as verifier. Session public key,
requested operation, and channel context SHALL be bound in a second
signed authorization object, not as extra Challenge fields.

#### Scenario: Success without a browser

- GIVEN a client that holds a key matching a local authorization
  subject and a pin for edge XID `E`
- WHEN it answers an edge-issued v1 Challenge with `aud = E` and then
  a session-bind object
- THEN the edge accepts the identity proof
- AND no authorization-code or device-code grant is used

#### Scenario: Wrong edge

- GIVEN a Challenge with `aud` not equal to the client's pinned XID
- WHEN the client or the edge checks the exchange
- THEN it is rejected
- AND it is not treated as a fallback to hosted OIDC

#### Scenario: Replay and expiry

- GIVEN a previously accepted Response
- WHEN it is presented again, or after `exp`
- THEN it is rejected

#### Scenario: Altered request and holder substitution

- GIVEN a valid Response for a Challenge
- WHEN the session-bind object is altered or signed by a different
  holder key than the Response
- THEN the edge rejects the bind

#### Scenario: Custody is not on the wire

- GIVEN a v1 Response produced by a local wallet or by a managed
  claimant
- WHEN the edge verifies it
- THEN both shapes are accepted the same way
- AND the edge does not infer C1–C4 from the Response

### Requirement: Bind is a same-holder authorization object

The session-bind object SHALL be signed by the same classical key as
the v1 Response, over a domain-separated payload that includes the
exact challenge bytes, session public key, canonical
operation/resource, and authenticated channel. The edge SHALL reject
a bind attached to a different valid exchange. Local policy SHALL
still deny an operation the subject is not allowed. C1/C2 managed
completion SHALL obtain a holder bind signature under consent that
covers the bind fields; the Challenge Response SHALL NOT stand in
for that consent.

#### Scenario: Bind on a different exchange is rejected

- GIVEN a valid Response for Challenge `C1` and a bind that verifies
  for `C1`
- WHEN that bind is presented with a different valid Challenge `C2`
- THEN the edge rejects the bind

#### Scenario: Signed operation still needs policy

- GIVEN a valid same-holder bind for operation `vms:stop`
- WHEN local policy does not allow that subject to stop VMs
- THEN authorization fails
- AND identity proof may still have succeeded

### Requirement: Channel binds the current authenticated peer

Channel context SHALL be adapter-authenticated for this connection.
For public HTTPS the TLS terminator (`mjolnir-gateway`) SHALL assign
`server_conn_id` on the external origin-TLS session, compute
`Blake3(SPKI(served_origin_cert) || server_conn_id)`, return that
id beside the Challenge, and inject conn_id plus origin SPKI to the
API only over a trusted backend (loopback or UDS) after stripping
client-supplied copies of those fields. The verifier SHALL compute
the expected channel from those injected values independently of
the submitted proof. Iroh channel SHALL be
`Blake3(peer_iroh_node_id || conn_id)` on that Iroh connection, and
the node id SHALL match the operational-key edge-proof of the pin.
Plain HTTP SHALL be deferred. A bind SHALL be rejected when those
inputs are missing, when replayed on another connection of the same
transport, or when the peer fails edge-proof of the pinned XID even
if `aud` matches.

#### Scenario: Same-transport replay is rejected

- GIVEN an unconsumed identity+bind issued on connection `N1`
- WHEN those same bytes are first presented on connection `N2` of
  the same transport
- THEN they are rejected for channel mismatch
- AND the nonce is not consumed
- WHEN the same unconsumed bytes are then presented on `N1`
- THEN the edge issues exactly one capability
- WHEN they are presented again on `N1`
- THEN that submit is replay (no second grant)

#### Scenario: Wrong peer, correct aud

- GIVEN a Challenge with `aud` equal to pin `E`
- WHEN a peer that cannot prove `E` presents it
- THEN the exchange is rejected

#### Scenario: Untrusted hop cannot supply channel

- GIVEN a request that did not arrive from the gateway’s trusted
  backend
- WHEN it carries client-supplied conn_id or origin-SPKI fields
- THEN channel is unavailable
- AND the bind is refused

### Requirement: Nonce consume and issuance are one commit

The edge SHALL NOT consume the identikey-auth nonce before bind
verification and issuance commit succeed together. One commit SHALL
record consumption and issuance; no usable credential SHALL exist
before that commit. Invalid bind and any pre-commit failure SHALL
leave the nonce unconsumed. Concurrent duplicates SHALL yield at
most one grant. Delivery loss after commit SHALL NOT undo issuance
or mint a replacement from the old proof. Restart SHALL restore the
last commit. There SHALL be no durable consumed-without-issue
state.

#### Scenario: Combined success

- GIVEN a valid v1 Response and a valid same-holder bind on `N1`
- WHEN the edge commits
- THEN identity is accepted
- AND exactly one capability is issued
- AND the nonce is consumed

#### Scenario: Unused proof expiry is independent of replay

- GIVEN a Response that has never been accepted
- WHEN it is presented after `exp`
- THEN it is rejected for expiry

#### Scenario: Invalid bind does not issue

- GIVEN a valid v1 Response and an invalid bind
- WHEN the edge processes them
- THEN no capability is usable
- AND the nonce is not consumed
- AND the client may retry bind on the same challenge

#### Scenario: Policy denial does not consume

- GIVEN a valid same-holder bind for an operation local policy
  denies
- WHEN the edge processes it
- THEN no capability is usable
- AND the nonce is not consumed

#### Scenario: Pre-commit failure retries

- GIVEN identity and bind verified but commit not yet durable
- WHEN the process crashes
- THEN no capability is usable
- AND the nonce is unconsumed
- AND a retry on the same connection may complete the commit

#### Scenario: Concurrent submissions have one winner

- GIVEN one unconsumed valid identity+bind
- WHEN two commits race
- THEN exactly one capability is issued
- AND the loser is replay

#### Scenario: Post-commit loss requires a fresh challenge

- GIVEN a successful commit whose capability bytes never reached
  the client
- WHEN the client presents the old proof, including after restart
- THEN it is rejected
- AND the client must start a new challenge
- AND if restart closed `N1`, the new challenge is on a new
  connection

