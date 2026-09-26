# edge-auth

What is built. Seeded by
[`add-biscuit-profiles`](../../changes/archive/2026-09-26-add-biscuit-profiles/proposal.md)
on 2026-09-26 (bead `mjolnir-22ff.5`, steer 2026-09-24); the edge pin
and operational-key requirements were folded from
[`add-edge-op-keys`](../../changes/archive/2026-09-26-add-edge-op-keys/proposal.md)
the same day (bead `mjolnir-22ff.2`). This is the
Mjolnir **login profile** over the shared mint/verify runtime, living
spec [`biscuit-runtime`](../biscuit-runtime/spec.md) — not a second
runtime. Wire-format holder/hop/redeem SHALLs live in
identikey-protocol (`identikey-capability-v1`) and are deliberately
**not** copied here.

## Purpose

Direct edge auth mints an edge-scoped capability. Its ADR is
[`0012-direct-edge-auth`](../../../docs/decisions/0012-direct-edge-auth.md),
which fixes the trust pin, the stable/operational key split, and
"discovery is not TOFU". The operational mint root and delegations the
login profile treats as trusted input are the subject of the first two
requirements below; the BEAM face is `Mjolnir.Auth.EdgeKeys`
(`provision/1`, `load/1`, `rotate/1`, `delegate/4`, `verify_chain/4`,
`supersede/4`, `sign_operational/4`, `verify_capability_window/4`,
`attest_restore/4`, `activate_restore/4`), reading `:auth_dir`
(`/var/lib/mjolnir/auth`) — deliberately not under `btrfs_root`, so a
subvolume snapshot cannot capture private key bytes.

If that capability were a bearer JWT-shaped secret, theft would be
privilege. So the default login profile is **holder-bound**: the
IdentiKey exchange authorizes an ephemeral
session public key and every protected request proves possession of
it. Bearer is an explicit, strictly narrower issuance option with an
unambiguous mode bit, so a verifier can never treat a holder-bound
token as bearer.

The BEAM face is `Mjolnir.Auth.LoginProfile` (`mint/3`,
`mint_holder/3`, `mint_bearer/4`, `authorize/4`, `sign_proof/6`,
`proof_signing_bytes/5`, `proof_challenge/5`), which packs an
issuer-signed profile envelope (`MJLP1`) ahead of the Biscuit bytes.
Holder fingerprints are the identikey-auth v1 §5 dCBOR map, *not*
`IdentiKey.fingerprint/1`.

Not built by this node, and named so the gap is not mistaken for
drift: the HTTP mint at login and the nonce store
(`add-direct-auth-endpoints`), the `Mjolnir.API.Auth` plug wiring,
tokenator redeem (`mjolnir-axsb.1.4`), VM-spawn RBAC
(`mjolnir-k8y.5`), and numeric lifetime windows (config, chosen at
the endpoints node). The rules below are not config.

## Requirements

### Requirement: Edge identity is a pinned XID with rotating operational keys

The edge SHALL hold a stable IdentiKey (the pin) and one or more
operational keys under `/var/lib/mjolnir/auth` with mode `0600`. Those
files SHALL NOT live under `btrfs_root`. The stable identity key SHALL
NOT be required online for ordinary sessions. Operational keys SHALL
sign edge proof and capability issuance. A client SHALL treat the
configured stable XID as the trust root; mesh, DNS, and Iroh addresses
SHALL NOT substitute for that pin. First use without a pin SHALL fail
closed.

#### Scenario: Offline chain verifies

- GIVEN a stable edge XID and a current operational key delegated from it
- WHEN an offline verifier checks the chain
- THEN the operational key is accepted as that edge
- AND the stable private key is not required for the check

#### Scenario: Rotation does not drop unexpired capabilities

- GIVEN a capability signed by operational key `K1` that is still unexpired
- WHEN the edge rotates to `K2` with overlap
- THEN a verifier that knows the chain still accepts the `K1` capability
- AND new capabilities are issued by `K2`

#### Scenario: Snapshot does not capture edge keys

- GIVEN keys stored under `/var/lib/mjolnir/auth`
- WHEN a BTRFS snapshot of `btrfs_root` is taken
- THEN the snapshot does not contain the stable or operational private keys

#### Scenario: No pin is not TOFU

- GIVEN a client with no configured edge XID
- WHEN it reaches a Mjolnir API over any discovery path
- THEN it does not persist a discovered XID as trusted
- AND direct authentication is refused until a pin exists

### Requirement: Operational keys are delegated, not self-asserted

An operational key SHALL be accepted only with a delegation signed by
the pinned XID’s identity key covering operational public, key id,
edge XID, purposes `{edge-proof, cap-mint}`, validity interval, and
no onward delegation. A key id SHALL NOT be treated as proof of
authority. Direct-auth functions SHALL fail closed when established
operational state is missing or corrupt and the stable private is
unavailable; hosted JWT verification SHALL remain independently
available. Generation of an undelegated key SHALL NOT activate it.
The last-activated {private key, matching delegation, current-kid}
bundle SHALL be crash-consistent. Auth-dir paths SHALL be `0700`/`0600`
at creation **and at open**; a private file or directory whose mode
does not match SHALL fail closed for direct auth. Paths SHALL NOT
alias into `btrfs_root`.

#### Scenario: Tampered or wrong-purpose delegation is rejected

- GIVEN a pin for edge XID `E` and a delegation that is altered, or
  that lists a purpose other than `{edge-proof, cap-mint}`
- WHEN an offline verifier checks it
- THEN the operational key is not accepted

#### Scenario: Reused kid with substituted public is rejected

- GIVEN a valid delegation for kid `K1` and public `P`
- WHEN a different public is presented with kid `K1`
- THEN verification fails

#### Scenario: Root-offline restart with valid delegation

- GIVEN a persisted delegated operational key and no accessible
  stable private
- WHEN the edge starts
- THEN edge-proof and cap-mint using that operational key work
- AND the stable identity is unchanged

#### Scenario: Missing op-key state without root fails closed for direct auth

- GIVEN established pin `E` and missing or corrupt operational state
  and no stable private
- WHEN a client attempts direct authentication
- THEN direct auth is refused
- AND hosted JWT verification is unaffected

#### Scenario: Stale verifier and retired K1

- GIVEN K1’s delegation has been superseded or has expired
- WHEN a verifier that still holds only the old K1 delegation is
  shown a capability newly signed by K1
- THEN acceptance lasts at most until that verifier’s K1 delegation
  `exp`
- AND a verifier with the supersession rejects it immediately

#### Scenario: Unsafe path is rejected

- GIVEN a configured auth dir that resolves under `btrfs_root`
- WHEN the edge loads key state
- THEN the path is not used
- AND direct auth fails closed

#### Scenario: Attacker document cannot steal a pin

- GIVEN pin `E` whose inception public is `P`
- WHEN a different key pair presents a document labeled `E`
- THEN verification fails

#### Scenario: Capability cannot outlive its delegation

- GIVEN operational key `K1` whose delegation `exp` is T
- WHEN a capability signed by `K1` has `exp` after T
- THEN mint or verify fails

#### Scenario: Stale backup is not live authority

- GIVEN a restored auth bundle whose supersession log is a prefix of
  already-observed kids
- WHEN the edge would activate it without a recovery attestation
- THEN direct auth stays fail-closed

#### Scenario: Old attestation cannot revive a retired kid

- GIVEN backup `B1` and a valid restore attestation `A1` from when
  `K1` was current
- AND `K1` was later superseded by `K2`
- WHEN the operator presents `B1+A1` after loss of the active dir
- THEN `B1` is not activated
- AND a fresh ceremony must attest a reconciled output that still
  contains the `K1` supersession

#### Scenario: Missing current recovery evidence fails closed

- GIVEN only a stale backup and no independently retained
  revocation list
- WHEN the operator cannot establish current revocations
- THEN direct auth for that XID stays fail-closed

#### Scenario: Interrupted activation keeps learned revocation

- GIVEN a durable supersession of `K1` and an activation that
  crashes after that write
- WHEN the edge recovers
- THEN `K1` remains superseded
- AND the previous consistent bundle is used or direct auth fails
  closed

#### Scenario: Permission at open is enforced

- GIVEN an otherwise valid auth private file whose mode is not
  `0600`, or a directory whose mode is not `0700`
- WHEN the edge opens it
- THEN direct auth fails closed

#### Scenario: Supersession target tamper is rejected

- GIVEN a valid `op-supersede` for kid `K1`
- WHEN the target kid in the signed tuple is altered
- THEN the supersession does not verify
- AND `K1` remains valid until its own grant `exp` or a valid
  supersession

#### Scenario: Late-received supersession still revokes

- GIVEN `K1` grant expiry `T` and a valid `op-supersede` with
  effective time `R < T`
- WHEN a verifier first receives it at `R+1`
- THEN `K1` is rejected for the rest of `[R, T]`
- AND the supersession record is not discarded as expired
- AND after restart, a replay of the old `K1` grant is still
  rejected

#### Scenario: Unrevoked K1 survives K2 and K3

- GIVEN overlapping delegations for `K1`, `K2`, and `K3` and no
  supersession of `K1`
- WHEN a verifier checks a still-unexpired `K1` capability
- THEN it is accepted
- AND public evidence for `K1` is retained until `K1` delegation
  `exp` or a later supersession

#### Scenario: Stolen stable private requires a new pin

- GIVEN the stable identity private has leaked
- WHEN an attacker signs a fresh operational delegation for the old XID
- THEN clients that still pin that XID accept the attacker
- AND recovery is a new identity and a new pin, not a supersession
  of the leaked root

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
body_hash, edge_xid, nonce, exp]` as specified in seeding design
[Decision 7](../../changes/archive/2026-09-26-add-biscuit-profiles/design.md).
`biscuit_hash` SHALL be Blake3 of the exact presented token bytes.
`request_target` SHALL include the raw query string when present. The
nonce SHALL be edge-issued and consumed atomically with accepting the
effect. The edge SHALL reject wrong key, different token bytes,
altered body, query/method/path substitution, wrong audience, stale
or unknown nonce, concurrent reuse, and post-restart replay of a lost
nonce. The verifier SHALL inject `holder(fp)` only after that proof
succeeds. Failure SHALL NOT fall back to bearer.

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

- GIVEN a biscuit whose mint root is not this edge's operational
  delegated key
- WHEN it is presented
- THEN it is rejected
