## ADDED Requirements

### Requirement: Secret-redemption biscuits are holder-bound

A Biscuit that authorizes `redeem` of a foreign secret SHALL name the
holder that may perform it. v1 holder class is a single Identikey
public key. The token SHALL carry a holder **check**
(`check if holder($fp), $fp == "<fingerprint>"`) and SHALL NOT
assert a `holder` fact in any block. Fingerprint is the Blake3
identity fingerprint from identikey-auth-challenge v1 §5. A verifier
SHALL NOT treat possession of the token bytes as sufficient. It
SHALL verify a signature by that key over a single signed tuple
(token identity, verifier-chosen nonce, audience; plus a response
key if the profile seals the release), compute the fingerprint from
the presented `{alg, key}`, inject the `holder(<fingerprint>)`
**fact** (verifier-injected only), then evaluate the Biscuit. A
failed holder proof SHALL fail closed. Encoding of the tuple and
the definition of token identity stay with `add-biscuit-runtime` /
`ikp-6yz.2`.

This requirement SHALL NOT apply to other agency profiles (VM exec,
mailbox, snapshot) unless those profiles add it. A root VM-exec
Biscuit without a holder check is not a violation of this spec.

#### Scenario: Stolen token without the named key

- GIVEN a Biscuit bound to public key Z
- WHEN a presenter who cannot sign as Z requests evaluation
- THEN the verifier rejects
- AND the authorized operation does not run

#### Scenario: Named key presents

- GIVEN the same Biscuit
- WHEN Z signs the tuple (token identity, nonce, audience)
- AND the Biscuit's other checks pass
- THEN the verifier accepts the injected holder fact
- AND evaluation may proceed

#### Scenario: Token asserts a holder fact

- GIVEN a minted Biscuit whose authority or attenuation block
  contains a `holder` fact
- WHEN a verifier evaluates it
- THEN the verifier rejects
- AND redeem does not run

### Requirement: Secret bytes stay out of the token

A Biscuit SHALL NOT contain the bytes of a foreign secret (GitHub
PAT, API key, or equivalent), nor a ciphertext of those bytes that
the presenter can decrypt without the verifier. It MAY name a secret
identifier and SHALL, if it carries a digest of the secret, use a
**salted** Blake3 commitment (`Blake3(domain || salt || secret)`).
Salt MAY travel with the token. An unsalted hash of the secret
SHALL NOT appear on the wire (Recrypt D-5: salting is mandatory
for low-entropy secrets). Copy-out (release of `{value, salt}`
to the holder; defined by `add-secret-tokenator`) SHALL be
verifiable against that commitment. Holder fingerprints SHALL be
Blake3 per auth-challenge v1 §5, not a SHA-256 stub and not a
raw-Ed25519 preimage. The secret-redemption profile is an
online-verifier application of agency; it does not weaken
capability-v1 §2 for other profiles.

#### Scenario: Inspect minted token

- GIVEN a Biscuit minted for secret `github-pat-ci`
- WHEN the token bytes are parsed
- THEN they do not contain the PAT
- AND they do name the secret identifier (or equivalent resource)
- AND any digest of the secret is salted Blake3, not `Blake3(secret)`

#### Scenario: Unsalted secret hash on the wire

- GIVEN a change that puts an unsalted hash of a foreign secret on
  a Biscuit, mailbox payload, or elided envelope
- WHEN it is reviewed
- THEN it is rejected against this requirement

### Requirement: Hop provenance is the Biscuit block chain

v1 redeem SHALL succeed with zero hop blocks when the issuer bound
the holder at mint. When a hop is recorded, it SHALL be a Biscuit
block on that token, not an `identikey-log` (or other) op. A hop
SHALL NOT remove holder checks or widen rights.

v1 hop blocks are **nextKey attenuation**: signed by the token's
current nextKey, which the holder of the bytes has. That proves
monotonicity, not Identikey attribution. Identikey-signed hops
SHALL use Biscuit third-party blocks and are not v1
(`add-capability-hop`).

#### Scenario: Issuer-bound token, no hops

- GIVEN a Biscuit minted with holder Z and never appended
- WHEN Z presents a valid holder proof
- THEN redeem may succeed
- AND missing hop blocks are not a failure

#### Scenario: Second provenance format proposed

- GIVEN a change that records hops only in `identikey-log` (or
  another log) and not as Biscuit blocks
- WHEN it is reviewed
- THEN it is rejected against this requirement

#### Scenario: Identikey key as biscuit nextKey

- GIVEN a change that requires each hop to sign the attenuation
  block with the forwarder's Identikey (including P-256 enclave
  keys)
- WHEN it is reviewed
- THEN it is rejected against this requirement (v1 is nextKey;
  Identikey attribution is third-party blocks, later)

### Requirement: Foreign-secret redemption is agency, not PRE

Redeeming a foreign secret SHALL be specified as an agency operation
on a Biscuit (`redeem` of a named secret), verified by a tokenator
that already holds the secret. Recrypt PRE SHALL remain the layer
for *our* ciphertext. A design that puts Recrypt-protected data
behind this tokenator, or that PRE-transforms a GitHub PAT, SHALL be
rejected.

The verifier SHALL release the secret only to the party that
completed the holder proof, over a channel that delegation-path
intermediaries cannot read. Application profiles choose the
binding: host-local overlay where the holder is the socket peer
(Mjolnir v1), a transport authenticated to the holder key, or
sealing the response to a response key carried in the signed
holder proof.

#### Scenario: PAT is the example foreign secret

- GIVEN an owner holds a GitHub PAT in a store the tokenator can
  read
- WHEN agent Z presents a valid holder-bound Biscuit for that secret
  over a holder-bound channel
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
