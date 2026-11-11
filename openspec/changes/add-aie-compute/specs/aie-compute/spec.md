## ADDED Requirements

### Requirement: Guest never receives the NPU device

The host SHALL keep the NPU bound to the host KMD. A Mjolnir guest
SHALL NOT be given `/dev/accel`, `/dev/dri`, or VFIO of the NPU
PCI function. Sharing AIE compute SHALL be overlay HTTP to a host
sidecar, not device passthrough.

#### Scenario: Guest has no accel node

- GIVEN a running guest on a host that has `/dev/accel/accel0`
- WHEN that guest lists `/dev/accel` and `/dev/dri`
- THEN both paths are absent
- AND the guest can still reach the sidecar locator when the sidecar is up

### Requirement: Overlay locator when the sidecar is up

The sidecar SHALL bind `:host_api_ip` (default `10.200.0.1` on
`dummy-mjolnir`) and SHALL NOT bind `0.0.0.0` or loopback. Guest
TCP to that address SHALL be INPUT. When the sidecar is up, every
boot SHALL inject `aie_url` into `/etc/mjolnir/vm.json`. When
`/dev/accel/accel0` is missing or the sidecar is stopped, the host
SHALL omit `aie_url`. Omitting `aie_url` SHALL NOT remove
`api_url`, `blob_door_url`, or other sidecar locators.

#### Scenario: Locator present on an NPU host

- GIVEN a host with `/dev/accel/accel0` and a running AIE sidecar
- WHEN a guest boots
- THEN `/etc/mjolnir/vm.json` contains `aie_url` pointing at
  `http://10.200.0.1:<aie_compute_port>`
- AND `blob_door_url` is still present

#### Scenario: Locator absent without a device

- GIVEN a host with no `/dev/accel/accel0`
- WHEN a guest boots
- THEN `/etc/mjolnir/vm.json` has no `aie_url` key
- AND `blob_door_url` is unchanged

### Requirement: VM being is the offer principal

An AIE offer SHALL be named by the sharing VM's IdentiKey. The
sidecar process SHALL NOT be the IdentiKey principal. Execute
SHALL authorize against that offer. When the named VM is gone, the
sidecar SHALL refuse execute for that offer.

#### Scenario: Host process is not the offerer

- GIVEN a sidecar process running as root on the host
- WHEN a client presents a token bound only to that process identity
- THEN execute is refused

#### Scenario: Missing being fails closed

- GIVEN an offer whose VM id is no longer running or dormant-restorable
- WHEN execute is presented for that offer
- THEN the sidecar refuses
- AND the NPU program is not loaded

### Requirement: Execute is a holder-checked Biscuit

Execute SHALL require a Biscuit with
`right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")` and a
holder check using the identikey-auth v1 §5 fingerprint.
`incarnation` SHALL be Blake3 of the canonical signed offer-leaf
bytes at mint. The sidecar SHALL authenticate the request before
injecting `holder("<fp>")`: the caller proves possession of the
holder private key over a `mjolnir/aie-execute/v1` length-prefixed
frame that binds biscuit, single-use nonce, audience (this host
mint-root fingerprint and `aie_url` origin), the offer resource
including incarnation, Blake3 of the submitted job, and an
idempotency key. The verifier SHALL compute the fingerprint
from the proof public key. Token-supplied `holder` facts SHALL NOT
satisfy the check. A holderless token SHALL be refused. The biscuit
crate SHALL NOT grow HTTP. The token SHALL NOT carry secret bytes.
Mint of a holder-bound token SHALL NOT require a guild identifier.
Mint issuer SHALL be this host's durable production Biscuit root.
The sidecar SHALL refuse a token from any other issuer.

#### Scenario: Holder mismatch is refused

- GIVEN a token with a holder check for fingerprint Z
- WHEN a caller whose fingerprint is not Z presents it
- THEN execute is refused
- AND the NPU program is not loaded

#### Scenario: Mint without a guild still works

- GIVEN this host's mint root, an issuer instruction from the offer
  being, and a target public key Z
- WHEN they mint a holder-bound execute token for a personal-fp offer
- THEN no guild or keyspace identifier is required
- AND Z can execute that personal-fp offer after a valid request proof

#### Scenario: Stolen token without possession proof is refused

- GIVEN biscuit bytes for Z and Z's public key
- WHEN a presenter who does not control Z's private key submits them
- THEN execute is refused before holder injection
- AND the NPU program is not loaded

#### Scenario: Replay and rebound job are refused

- GIVEN a valid proof for offer R and job digest J
- WHEN that proof is replayed, or presented with a different job or offer
- THEN execute is refused
- AND the NPU program is not loaded

#### Scenario: Untrusted issuer is refused

- GIVEN a well-formed token minted by a key that is not this host's
  production root
- WHEN execute is presented with a valid request proof
- THEN execute is refused

### Requirement: Guild-scoped offers inject membership

When the **current** verified offer names a guild or Recrypt
keyspace, execute SHALL succeed only if, at admission, the verifier
injects `member(<ks>, <pk>)` from a trusted lookup performed at
occupancy-lock acquire whose public key is the holder proof key and
whose `ks` is the offer's named keyspace. Enqueue-time membership
evidence SHALL NOT authorize admission. A lookup response SHALL be
used only for that admission attempt and only if its provider
`issued-at` is within the provider max-age. A lookup that reports
non-member, or is missing, expired, or unavailable, SHALL fail
closed even if older evidence is still within TTL. Token-authored
`member` facts SHALL NOT count. A personal-fp offer SHALL NOT
require that lookup. The Biscuit authority block shape SHALL NOT
gain a new crypto layer for membership. Policy is the offer record
at occupancy-lock acquire, not at enqueue. A tombstone or
replacement SHALL produce a new incarnation and SHALL invalidate
prior grants at admission even when holder and policy still match.
Work already loaded MAY finish after withdrawal; queued work SHALL
revalidate and SHALL NOT start if the current offer or membership
refuses it. Enqueue SHALL consume the client nonce once; admission
revalidation of that queued request SHALL NOT consume a second
client nonce.

#### Scenario: Guild member runs

- GIVEN a guild-scoped offer and a caller in that guild with fresh
  trusted membership evidence
- WHEN they present a valid execute proof at admission
- THEN execute proceeds (subject to occupancy)

#### Scenario: Stranger is fail-closed

- GIVEN a guild-scoped offer and a caller with a valid request proof
  and no trusted membership
- WHEN they present execute
- THEN the sidecar refuses
- AND the NPU program is not loaded

#### Scenario: Removed member and withdrawn offer fail at admission

- GIVEN a queued job that was valid at enqueue
- WHEN membership is removed, or the offer is tombstoned, or a
  personal offer is replaced by a guild-scoped one, before admission
- THEN the job is refused at admission
- AND the NPU program is not loaded for that job

#### Scenario: Member key mismatch is refused

- GIVEN membership evidence for public key A and a holder proof for B
- WHEN execute is presented
- THEN it is refused

#### Scenario: Removal before TTL expiry fails at admission

- GIVEN a queued guild-scoped job whose enqueue-time membership
  evidence is still within TTL
- WHEN the member is removed, then admission runs a trusted lookup
- THEN the lookup reports non-member
- AND execute is refused
- AND enqueue-time evidence is not used

#### Scenario: Removal after the freshness bound fails at admission

- GIVEN membership evidence whose `issued-at` is older than max-age
- WHEN admission is attempted
- THEN execute is refused

#### Scenario: Membership lookup failure fails closed

- GIVEN a guild-scoped offer and a valid execute proof
- WHEN the trusted membership lookup is unavailable at admission
- THEN execute is refused
- AND the NPU program is not loaded

### Requirement: Capacity is a signed keyspace claim

An offer SHALL be a signed SecretStore record under the owner's
IdentiKey fingerprint (`owner_fp`). Canonical execute resource SHALL
be `{owner_fp, offer_id}` plus `incarnation` (Blake3 of the
canonical signed leaf). `VM.spawn/1` SHALL NOT create that record.
A missing, unsigned, wrong-fingerprint, or other-being VM offer
SHALL not authorize execute. Publish and mint SHALL require the
named VM's IdentiKey to equal the keyspace owner. Equal local
`offer_id` values in different owner keyspaces SHALL be distinct
rights. Mint SHALL copy incarnation from the current verified leaf.
Admission SHALL refuse a token whose incarnation does not equal
Blake3 of the current verified leaf. A tombstone or missing leaf
SHALL refuse. Recreating a leaf after a tombstone SHALL mint a new
incarnation and SHALL NOT revive a prior grant. Verifier restart
SHALL NOT revive a prior grant.

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

#### Scenario: Replacement invalidates the old incarnation

- GIVEN token T1 minted for offer `A/npu` at incarnation I1
- WHEN that offer is replaced under the same key with unchanged
  policy and the same holder presents T1 with a fresh proof
- THEN execute is refused before load
- AND a newly minted T2 for incarnation I2 succeeds for that holder

#### Scenario: Personal-to-guild replacement rejects the old token

- GIVEN token T1 minted for a personal offer
- WHEN that offer is replaced by a guild-scoped leaf at the same
  `{owner_fp, offer_id}` and T1's holder is a current guild member
- THEN T1 is refused at admission
- AND a token minted for the new incarnation may succeed

#### Scenario: Tombstone recreation does not revive an old grant

- GIVEN token T1 for incarnation I1, then a tombstone of that leaf,
  then a new signed leaf at the same `{owner_fp, offer_id}`
- WHEN T1 is presented after verifier restart
- THEN execute is refused
- AND the new leaf has a different incarnation

### Requirement: Sidecar serializes NPU occupancy

The sidecar SHALL use the same IRON Lab occupancy flock identity as
cooperating `ironlab` entry points. It SHALL acquire that lock
immediately before xclbin load and SHALL release it only after the
XRT worker is reaped and the device is quiescent. A second execute
while a program is loaded SHALL wait or return busy. Timeout and
cancel SHALL wait for quiescence before release. If quiescence
cannot be established, new execute SHALL be refused until recovery.
The lock is advisory against non-cooperating host clients.

#### Scenario: Second run does not clobber

- GIVEN a run in progress that holds the occupancy lock
- WHEN a second execute arrives
- THEN the first run's program stays loaded until it finishes
- AND the second run does not start a second loaded design on the array

#### Scenario: Timeout does not overlap a new load

- GIVEN a run whose request timed out or was cancelled
- WHEN a second execute arrives
- THEN the sidecar does not load a second design until the first
  worker is quiescent or new execute is refused

#### Scenario: Restart with a live worker fails closed

- GIVEN a sidecar restart while an XRT worker from the previous
  process is still alive
- WHEN a new execute arrives
- THEN the sidecar preserves exclusion or refuses until safe recovery
