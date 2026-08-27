## ADDED Requirements

### Requirement: Holder is proven at use

A Biscuit that authorizes an operation SHALL name the holder class
that may perform it. v1 holder class is a single public key. A
verifier SHALL NOT treat possession of the token bytes as sufficient.
It SHALL verify a signature by that public key over a verifier-chosen
nonce (and the token identity), inject the corresponding Datalog
holder fact, then evaluate the Biscuit. A failed holder proof SHALL
fail closed.

#### Scenario: Stolen token without the named key

- GIVEN a Biscuit bound to public key Z
- WHEN a presenter who cannot sign as Z requests evaluation
- THEN the verifier rejects
- AND the authorized operation does not run

#### Scenario: Named key presents

- GIVEN the same Biscuit
- WHEN Z signs the nonce and audience
- AND the Biscuit's other checks pass
- THEN the verifier accepts the holder fact
- AND evaluation may proceed

### Requirement: Secret bytes stay out of the token

A Biscuit SHALL NOT contain the bytes of a foreign secret (GitHub
PAT, API key, or equivalent), nor a ciphertext of those bytes that
the presenter can decrypt without the verifier. It MAY name a secret
identifier as the resource of an agency operation such as `redeem`.

#### Scenario: Inspect minted token

- GIVEN a Biscuit minted for secret `github-pat-ci`
- WHEN the token bytes are parsed
- THEN they do not contain the PAT
- AND they do name the secret identifier (or equivalent resource)

### Requirement: Hop provenance is the block chain

Forwarding SHALL be expressed as Biscuit blocks signed by the
forwarding key. A separate op-log SHALL NOT be required to prove
which agents handled the token. A hop SHALL NOT remove holder checks
or widen rights.

#### Scenario: Second provenance format proposed

- GIVEN a change that records hops only in `identikey-log` (or
  another log) and not as Biscuit blocks
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Foreign-secret redemption is agency, not PRE

Redeeming a foreign secret SHALL be specified as an agency operation
on a Biscuit (`redeem` of a named secret), verified by a tokenator
that already holds the secret. Recrypt PRE SHALL remain the layer
for *our* ciphertext. A design that puts Recrypt-protected data
behind this tokenator, or that PRE-transforms a GitHub PAT, SHALL be
rejected.

#### Scenario: PAT is the example foreign secret

- GIVEN an owner holds a GitHub PAT in a store the tokenator can
  read
- WHEN agent Z presents a valid holder-bound Biscuit for that secret
- THEN the tokenator may return the PAT to Z
- AND intermediate agents who only forwarded the Biscuit do not
  receive it

#### Scenario: Recrypt ciphertext proposed as tokenator payload

- GIVEN a change that redeems Recrypt-protected object bytes through
  the foreign-secret tokenator instead of PRE
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Guild holder class is not v1

v1 SHALL bind a holder to one public key. Membership in a guild or
keyspace MAY be named as a future holder class (verifier-injected
membership fact or cryptographic proof). v1 SHALL NOT require a
membership lookup to accept a holder-bound token.

#### Scenario: v1 mint without a guild

- GIVEN an issuer and a target public key Z
- WHEN they mint a holder-bound Biscuit
- THEN no guild or keyspace identifier is required
