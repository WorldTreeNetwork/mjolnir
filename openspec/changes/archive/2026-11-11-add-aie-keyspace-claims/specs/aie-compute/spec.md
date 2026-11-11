## ADDED Requirements

### Requirement: Capacity is a signed keyspace claim

An offer SHALL be a signed SecretStore record under the owner's
IdentiKey fingerprint (`owner_fp`). Canonical execute resource SHALL
be `{owner_fp, offer_id}` plus `incarnation` (Blake3 of the
canonical signed leaf). `VM.spawn/1` SHALL NOT create that record.
A missing, unsigned, wrong-fingerprint, or other-being VM offer
SHALL not authorize execute. Publish and mint SHALL require the
named VM's IdentiKey to equal the keyspace owner **and** that VM
id to be on this host's operator-held allowlist of offering VMs.
Equal local `offer_id` values in different owner keyspaces SHALL
be distinct rights. Mint SHALL copy incarnation from the current
verified leaf. The leaf SHALL carry a strictly increasing sequence.
A tombstone SHALL be retained as a floor. Put of a leaf at or below
that floor, including re-put of retired bytes, SHALL be refused.
v1 SHALL revoke by whole-offer replacement.

#### Scenario: Spawn does not mint capacity

- GIVEN a VM spawned with no prior offer record
- WHEN spawn returns
- THEN no AIE offer leaf exists in the owner's keyspace for that VM

#### Scenario: Unsigned offer is refused

- GIVEN bytes at the offer key that do not verify as the owner's
  signed envelope
- WHEN execute names that offer
- THEN execute is refused

#### Scenario: Cross-keyspace id collision does not share rights

- GIVEN owner A and owner B both published local id `npu`
- WHEN a token for `A/npu` is presented against `B/npu`
- THEN execute is refused

#### Scenario: Unrelated VM in a signed leaf is refused

- GIVEN an owner-signed offer that names a VM whose IdentiKey is
  not that owner
- WHEN execute or mint is attempted for that offer
- THEN it is refused

#### Scenario: Guest not on the allowlist cannot offer

- GIVEN a running VM whose IdentiKey equals its keyspace owner
  but whose VM id is not on the host allowlist
- WHEN it publishes or mints an AIE offer
- THEN publish and mint are refused

#### Scenario: Re-put of retired bytes is refused

- GIVEN a tombstone whose floor sequence is N and the exact
  signed bytes of a retired leaf at sequence ≤ N
- WHEN those bytes are put again at the same key
- THEN the put is refused
- AND tokens for that retired incarnation stay refused
