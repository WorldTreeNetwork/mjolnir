## ADDED Requirements

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


