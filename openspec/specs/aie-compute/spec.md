# aie-compute

What is built. Folded from
[`add-aie-host-sidecar`](../../changes/archive/2026-11-11-add-aie-host-sidecar/proposal.md),
[`add-aie-keyspace-claims`](../../changes/archive/2026-11-11-add-aie-keyspace-claims/proposal.md),
[`add-guild-compute-holder`](../../changes/archive/2026-11-11-add-guild-compute-holder/proposal.md),
[`add-aie-guest-offer`](../../changes/archive/2026-11-11-add-aie-guest-offer/proposal.md),
and architecture
[`add-aie-compute`](../../changes/archive/2026-11-11-add-aie-compute/proposal.md)
on 2026-11-11. ADR
[`0015`](../../../docs/decisions/0015-aie-compute-sidecar.md).

## Purpose

Host AIE sidecar on `:host_api_ip:7422`. Dedicated `mjolnir-aie`
user, BEAM admit on `aie-admit.sock`, occupancy flock, locator
`aie_url` in the guest map. Guests do not receive the NPU.
Capacity is a signed SecretStore offer leaf under the owner's
keyspace; spawn does not mint it. Guild-scoped offers inject
membership after try-lock via `Mjolnir.Aie.Guild.admit/1`
(roster + current `mjolnir/aie-delegate/v1` leaf). Personal-fp
offers skip lookup. The Biscuit authority block does not gain
a `member` fact. The offer principal is the sharing VM's
IdentiKey. Guests use `mj compute share` / `mj compute run` and
`POST {aie_url}/v1/execute` (catalog `design_id` + bounded
input). Retry of a live `pending_id` does not reset enqueue
time; after abandon the client needs a fresh nonce.

## Requirements

### Requirement: AIE sidecar unit binds the overlay

The AIE sidecar SHALL run as user `mjolnir-aie` in group
`mjolnir-aie`, SHALL NOT run as root, and SHALL be able to open
`/dev/accel/accel0`. It SHALL bind `:host_api_ip` (default
`10.200.0.1`) port `:aie_compute_port` (default `7422`) and SHALL
NOT bind `0.0.0.0` or loopback. Guest TCP SHALL be INPUT. Install
SHALL ride `just deploy`. The process SHALL NOT be given
`/run/mjolnir/operator.sock`.

#### Scenario: Sidecar is not root

- GIVEN a running AIE sidecar
- WHEN an operator inspects its unit user
- THEN the process is not uid 0
- AND it can open `/dev/accel/accel0`

#### Scenario: Bind is overlay only

- GIVEN the sidecar is running
- WHEN `ss` is inspected
- THEN it listens on `10.200.0.1:7422`
- AND it does not listen on `0.0.0.0:7422`

### Requirement: BEAM admit socket is scoped

The orchestrator SHALL listen on `/run/mjolnir/aie-admit.sock`
mode `0660` owner root group `mjolnir-aie`. That listener SHALL
NOT mark connections as operator and SHALL expose only enqueue
and admission. After BEAM or listener restart the socket SHALL
be recreated with the same path, mode, owner, and group.
`/run/mjolnir/operator.sock` SHALL remain `0600` root.

#### Scenario: Non-root sidecar can enqueue and admit

- GIVEN the sidecar user in group `mjolnir-aie`
- WHEN it calls enqueue then admission for a valid proof
- THEN both calls succeed (subject to policy and occupancy)

#### Scenario: Unrelated local user cannot admit

- GIVEN the admit socket
- WHEN a uid not in group `mjolnir-aie` connects
- THEN the connect is refused

#### Scenario: Sidecar identity cannot use operator VM routes

- GIVEN the sidecar OS credential
- WHEN it calls VM spawn, exec, kill, or snapshot
- THEN the call is refused

### Requirement: Pending admit authorizes one live load

The BEAM SHALL own the pending table. Enqueue SHALL consume the
nonce once and return `pending_id`. Admission SHALL name
`pending_id` and occupancy `attempt_id`. Load SHALL require a
live success on the current attempt (lock held, deadline live,
no prior load). Cached `dispatched` after abandon SHALL NOT
authorize a load. Restart SHALL invalidate pending ids.

#### Scenario: Lost reply on a live attempt may load once

- GIVEN a dispatched `(pending_id, attempt_id)` whose reply was
  lost while the lock is still held within the deadline
- WHEN the sidecar retries that pair
- THEN the first load MAY start
- AND a second load does not start

#### Scenario: Abandoned attempt cannot load

- GIVEN deadline expiry or lock release
- WHEN a late success or retry of that `pending_id` arrives
- THEN the sidecar does not load

### Requirement: Occupancy flock serializes catalog jobs

The sidecar SHALL try-lock the IRON Lab flock, admit under a
deadline, then load a host-catalog design id or release. It
SHALL NOT load a guest-authored xclbin. It SHALL kill the
worker at the leaf wall time and release only after quiescence.

#### Scenario: Second run does not clobber

- GIVEN a run holding the occupancy lock
- WHEN a second execute arrives
- THEN the first program stays loaded until it finishes

#### Scenario: Guest xclbin is refused

- GIVEN an xclbin that is not a host-catalog design id
- WHEN execute is presented
- THEN admit refuses
- AND the sidecar does not load it

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
verified leaf. Admission SHALL refuse a token whose incarnation
does not equal Blake3 of the current verified leaf. The leaf
SHALL carry a strictly increasing sequence. A tombstone SHALL be
retained as a floor. Put of a leaf at or below that floor,
including re-put of retired bytes, SHALL be refused. A missing
leaf SHALL refuse. Recreating a leaf after a tombstone SHALL use
a sequence above the floor and SHALL NOT revive a prior grant.
v1 SHALL revoke by whole-offer replacement (no per-holder mint
expiry).

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

### Requirement: Guild-scoped offers inject membership

When the **current** verified offer names a guild or Recrypt
keyspace, execute SHALL succeed only if, at admission, BEAM
guild admission returns `:ok` for that occupancy attempt after
injecting `member(<ks>, <member_pk>)` from a trusted lookup and
a member-signed delegation leaf that names the **consumer VM**
holder. The holder proof key SHALL be the consumer VM IdentiKey.
A human member key SHALL NOT be required inside the guest.
Enqueue-time membership or delegation SHALL NOT authorize
admission. Lookup SHALL run after a successful occupancy
try-lock and under a hard deadline, then load or release. The
sidecar SHALL NOT wait on the IRON flock while a lookup is in
flight. A failed try-lock SHALL wait, then try-lock and
revalidate from scratch. A lookup response SHALL be used only
for that admission attempt and only if its provider `issued-at`
is within the provider max-age. A lookup that reports
non-member, missing delegation, expired, or unavailable SHALL
fail closed even if older evidence is still within TTL. A
personal-fp offer SHALL NOT require lookup or delegation. The
Biscuit authority block and `Biscuit.authorize/6` SHALL NOT
gain a membership fact, Datalog check, or new crypto layer for
membership; membership is verifier inject, not a
`mint`/`authorize` Datalog check. A personal-fp offer SHALL NOT
require that lookup or delegation. Token-authored
`member` facts SHALL NOT count. A tombstone or replacement
SHALL produce a new incarnation and SHALL invalidate prior
grants at admission even when holder and policy still match.
Work already loaded MAY finish after withdrawal; queued work
SHALL revalidate and SHALL NOT start if the current offer or
membership refuses it.

#### Scenario: Guild member runs

- GIVEN a guild-scoped offer naming G, consumer VM holder H, a
  current `mjolnir/aie-delegate/v1` leaf from member M to H for
  G, and a fresh roster response that M is a member of G
- WHEN H presents a valid execute proof at admission
- THEN execute proceeds (subject to occupancy)
- AND M's private key is not required in the guest

#### Scenario: Stranger is fail-closed

- GIVEN a guild-scoped offer and a caller with a valid request
  proof and no trusted membership
- WHEN they present execute
- THEN execute is refused
- AND the NPU program is not loaded

#### Scenario: Mint without a guild still works

- GIVEN this host's mint root and a personal-fp offer
- WHEN they mint a holder-bound execute token
- THEN no guild identifier is required
- AND lookup is not invoked at admission for that offer

#### Scenario: Token-authored member fact is ignored

- GIVEN a guild-scoped offer and a biscuit that asserts `member`
- WHEN roster membership or delegation is missing
- THEN execute is refused

#### Scenario: Removed member and withdrawn offer fail at admission

- GIVEN a queued job that was valid at enqueue
- WHEN membership is removed, or the offer is tombstoned, or a
  personal offer is replaced by a guild-scoped one, before admission
- THEN the job is refused at admission
- AND the NPU program is not loaded for that job

#### Scenario: Member key mismatch is refused

- GIVEN membership evidence for public key A and a holder proof for B
  with no delegation from A to B
- WHEN execute is presented
- THEN it is refused

#### Scenario: Consumer VM holder with member delegation runs

- GIVEN a guild-scoped offer, consumer VM holder H, and a
  member-signed delegation from member M to H
- WHEN H presents a valid execute proof and M is a current member
- THEN execute proceeds (subject to occupancy)
- AND M's private key is not required in the guest

#### Scenario: Lookup is not performed while waiting on the flock

- GIVEN occupancy is busy
- WHEN a second guild-scoped execute is queued
- THEN membership lookup does not run until a try-lock succeeds
- AND enqueue-time membership is not reused at that try-lock

#### Scenario: Removal after the freshness bound fails at admission

- GIVEN membership evidence whose `issued-at` is older than max-age
- WHEN admission is attempted
- THEN execute is refused

### Requirement: Member-signed delegation is a current leaf

A guild-scoped admission SHALL require a current
`mjolnir/aie-delegate/v1` leaf. Signing bytes SHALL be the
Redeem grammar: unprefixed domain `mjolnir/aie-delegate/v1`
then unsigned-big-32 length-prefixed fields: version (4-byte
u32be `1`), guild id UTF-8, member Ed25519 pubkey (32 bytes),
consumer-holder §5 fingerprint (32 bytes), purpose
`aie-execute`, issued-at (8-byte u64be), expires-at (8-byte
u64be), sequence (8-byte u64be). The member SHALL Ed25519-sign
those bytes. Implementations SHALL match the published 160-byte
signing-bytes vector in `design.md`. v1 consent SHALL be
guild-wide for AIE execute. The leaf's member pubkey SHALL
equal the selector and the roster `member_pk`. The leaf holder
fp SHALL equal the proven request holder fp. SecretStore
`identikey_fp` SHALL be `IdentiKey.fingerprint/1` of
`member_pk` (storage namespace). Current leaf SHALL be
`(storage_fp, "aie/delegate/<holder_fp58>")`. This node SHALL
register codec `aie_delegate`; envelope canonical signing
bytes SHALL equal the profile signing bytes. `expires-at`
SHALL be `> now`; `issued-at` SHALL be `<= now+5s`; lifetime
SHALL be `<= 86400s`.

#### Scenario: Publish and read back through SecretStore

- GIVEN a registered member identity and a valid `aie_delegate`
  envelope
- WHEN it is put at `(storage_fp, "aie/delegate/<holder_fp58>")`
  and then gotten
- THEN verify succeeds
- AND canonical signing bytes equal the profile vector for
  that field set

#### Scenario: Malformed encoding is refused

- GIVEN bytes that are not the profile grammar or not
  `type=aie_delegate`
- WHEN put or admission verify runs
- THEN they are refused

#### Scenario: Wrong-purpose or wrong-namespace is refused

- GIVEN a leaf with purpose other than `aie-execute`, or a put
  whose storage fp is not `IdentiKey.fingerprint(member_pk)`
- WHEN put or admission runs
- THEN it is refused

#### Scenario: Valid delegation admits

- GIVEN current leaf L for guild G, member M, holder H, unexpired
- WHEN admission checks L against proven holder H and roster M∈G
- THEN the delegation check succeeds

#### Scenario: Bad signature is refused

- GIVEN a leaf whose Ed25519 signature does not verify under M
- WHEN admission runs
- THEN execute is refused

#### Scenario: Wrong member or holder is refused

- GIVEN a leaf that names member M2 or holder H2
- WHEN roster membership is for M and the proven holder is H
- THEN execute is refused

#### Scenario: Cross-guild leaf is refused

- GIVEN a valid leaf for guild G1 and an offer that names G2
- WHEN admission runs
- THEN execute is refused

#### Scenario: Expired leaf is refused

- GIVEN a current leaf whose `expires-at` is in the past
- WHEN admission runs
- THEN execute is refused

#### Scenario: Withdrawn leaf cannot be replayed at admission

- GIVEN a previously valid leaf whose SecretStore key is now
  tombstoned, still unexpired
- WHEN that leaf is presented at admission
- THEN execute is refused

### Requirement: Selector names the member from pending inputs

`Guild.admit/1` SHALL read `member_pk` from the pending row
addressed by `pending_id`. That selector SHALL come from the
enqueue execute frame. A missing selector SHALL refuse. The
selector SHALL NOT by itself establish membership or signer
identity. Admit SHALL derive storage_fp from
`IdentiKey.fingerprint(member_pk)`, get the current leaf, call
`lookup(guild, member_pk)`, and compare signer, roster, holder,
and guild.

#### Scenario: Valid discovery from admit inputs

- GIVEN pending row with selector M, offer naming G, proven
  holder H, current leaf M→H for G, roster M∈G
- WHEN `admit/1` is called with that pending_id
- THEN it finds that leaf and returns `:ok`

#### Scenario: Missing selector is refused

- GIVEN a guild-scoped pending row with no `member_pk`
- WHEN `admit/1` runs
- THEN it returns error

#### Scenario: Forged or wrong-member selector is refused

- GIVEN selector M2 while the only valid leaf is M→H
- WHEN `admit/1` runs
- THEN it returns error
- AND M2's presence in the frame does not grant membership

### Requirement: Delegation writes use a sequence floor

One SecretStore key
`(storage_fp, "aie/delegate/<holder_fp58>")` SHALL hold the
current record: grant or withdraw tombstone. Its sequence SHALL
be the floor. Put SHALL require sequence > current (missing =
0) and the member's registered pubkey. Generic
`SecretStore.delete/3` SHALL NOT mutate this key. Intentional
regrant SHALL be a new grant with sequence > current and new
issued-at/expires-at.

#### Scenario: Replayed put after withdrawal is refused

- GIVEN tombstone at sequence N
- WHEN grant L at sequence ≤ N is put again
- THEN put is refused
- AND admission does not see L as current

#### Scenario: Rollback after replacement is refused

- GIVEN current grant at sequence N+1
- WHEN the sequence-N grant envelope is put again
- THEN put is refused

#### Scenario: Floor survives restart

- GIVEN current record sequence N
- WHEN the BEAM restarts and an envelope at sequence ≤ N is put
- THEN put is refused

### Requirement: Withdrawal is a distinct signed profile

Withdrawal SHALL use domain `mjolnir/aie-delegate-withdraw/v1`
and purpose `aie-withdraw`, Redeem grammar, member Ed25519
signature. Implementations SHALL match the published 170-byte
vector in `design.md`. A grant signature SHALL NOT authorize
withdrawal. A withdraw signature SHALL NOT admit as a grant.
Sequence N SHALL withdraw grants ≤ N for that `(member, holder)`.
A tombstone at sequence ≤ N SHALL NOT withdraw a later regrant
at M > N. Wrong-target (member or holder) SHALL be refused.

#### Scenario: Authorized withdrawal succeeds

- GIVEN current grant at sequence N, member M, holder H
- WHEN M puts a valid withdraw envelope at sequence N+1 for H
- THEN the current record is a tombstone
- AND later admission for H with selector M refuses

#### Scenario: Grant signature cannot withdraw

- GIVEN a valid grant envelope at sequence N+1
- WHEN it is submitted as a withdrawal
- THEN withdrawal is refused
- AND if put as a grant it follows grant rules only

#### Scenario: Tombstone cannot admit as a grant

- GIVEN current record is a withdraw envelope
- WHEN admission reads it
- THEN execute is refused

#### Scenario: Wrong-target withdrawal is refused

- GIVEN a withdraw envelope for holder H2 or member M2
- WHEN the current grant is M→H
- THEN put is refused

#### Scenario: Stale tombstone cannot withdraw a regrant

- GIVEN tombstone N, then grant M > N
- WHEN tombstone N is put again
- THEN put is refused
- AND grant M remains current

### Requirement: Admission reads one coherent snapshot

Admission SHALL read the current key once. Atomic rename of
that file SHALL be the commit point. Missing, unreadable,
malformed, or codec-mismatch bytes SHALL fail closed. A grant
snapshot SHALL authorize only as a grant at that sequence. A
tombstone SHALL never authorize. Interrupted mutation SHALL
leave the previous complete record. Concurrent admission SHALL
see one complete snapshot. Floor-reset via delete or
unrelated put SHALL be refused.

#### Scenario: Interrupted withdrawal leaves previous snapshot

- GIVEN current grant N and a withdrawal put that does not
  complete
- WHEN admission runs
- THEN it still sees grant N or, after commit, tombstone N+1
- AND it never mixes the two

#### Scenario: Concurrent admission versus withdrawal

- GIVEN grant N in flight of being replaced by tombstone N+1
- WHEN admission overlaps the put
- THEN it observes either complete grant N or complete
  tombstone N+1

#### Scenario: Partial or corrupt current bytes fail closed

- GIVEN unreadable or malformed bytes at the current key
- WHEN admission runs
- THEN execute is refused

#### Scenario: Floor-reset attempt is refused

- GIVEN tombstone at sequence N
- WHEN `SecretStore.delete/3` or a sequence-1 grant put is
  attempted
- THEN the mutation is refused
- AND floor remains N

### Requirement: Roster adapter is authenticated and fail-closed

Guild membership SHALL come from `Mjolnir.Aie.Guild.Roster`.
Host config SHALL map each guild/keyspace id to an endpoint and
authority public key. An unconfigured guild SHALL fail closed.
`lookup(ks, member_pk)` SHALL succeed only for a response
authenticated by that authority and bound to the queried pair.
`issued-at` SHALL be unix seconds within provider max-age
(default 60s) and not more than 5s in the future. Timeout,
unavailability, malformed, unauthenticated, wrong-subject, stale,
and future-dated evidence SHALL fail closed. A fresh negative
SHALL override an older still-within-TTL positive. The adapter
SHALL attest membership only. A stub that returns member SHALL
NOT satisfy this requirement.

#### Scenario: Removal before TTL expiry fails at admission

- GIVEN enqueue-time membership still within TTL
- WHEN the member is removed and admission lookups again
- THEN execute is refused
- AND enqueue-time evidence is not used

#### Scenario: Membership lookup failure fails closed

- GIVEN a guild-scoped offer and a valid execute proof
- WHEN the roster lookup times out or is unavailable
- THEN execute is refused

#### Scenario: Wrong-subject evidence is refused

- GIVEN a signed roster response for member M2 or guild G2
- WHEN admission queried (G, M)
- THEN execute is refused

#### Scenario: Malformed or unauthenticated response is refused

- GIVEN a roster body that does not verify under the configured
  authority for G
- WHEN admission lookups (G, M)
- THEN execute is refused

#### Scenario: Stale or future-dated evidence is refused

- GIVEN a verified response whose `issued-at` is older than
  max-age, or more than 5s in the future
- WHEN admission uses it
- THEN execute is refused

#### Scenario: Unconfigured guild fails closed

- GIVEN a guild-scoped offer naming G with no roster mapping
- WHEN admission runs
- THEN execute is refused

### Requirement: BEAM guild admit is an application gate

`add-aie-host-sidecar` SHALL call `Mjolnir.Aie.Guild.admit/1`
after a successful occupancy try-lock. Arguments SHALL be the
verified current offer, proven consumer holder fp, `pending_id`
(pending row includes `member_pk`), `attempt_id`, and deadline. Guild-scoped success SHALL require
valid execute proof AND valid Biscuit right/incarnation/holder
AND current roster membership AND current valid delegation for
that holder. Personal-fp offers SHALL skip only the guild
portion. A `:ok` for an abandoned `attempt_id` SHALL NOT
authorize a later attempt. Biscuit authorization alone SHALL
NOT admit a guild-scoped request.

#### Scenario: Biscuit alone does not admit a guild offer

- GIVEN a valid execute proof and matching Biscuit right
- WHEN roster membership or delegation is missing
- THEN `admit/1` returns error
- AND the sidecar does not load

#### Scenario: Missing guild gate does not load

- GIVEN a guild-scoped offer
- WHEN the sidecar would load without a successful `admit/1`
- THEN it SHALL NOT load

#### Scenario: Abandoned-attempt success is unusable

- GIVEN `admit/1` returned `:ok` for attempt T after T was
  abandoned
- WHEN a later occupancy attempt runs
- THEN that `:ok` does not authorize a load

### Requirement: VM being is the offer principal

An AIE offer SHALL be named by the sharing VM's IdentiKey. The
sidecar process SHALL NOT be the IdentiKey principal. Execute
SHALL authorize against that offer. When the named VM is gone,
execute for that offer SHALL be refused. The sidecar SHALL
refuse execute for that offer.

#### Scenario: Host process is not the offerer

- GIVEN a sidecar process running as `mjolnir-aie` on the host
- WHEN a client presents a token bound only to that process identity
- THEN execute is refused

#### Scenario: Missing being fails closed

- GIVEN an offer whose VM id is no longer running or dormant-restorable
- WHEN execute is presented for that offer
- THEN execute is refused
- AND the NPU program is not loaded

### Requirement: Guests execute on the locator with mj

The guest surface SHALL be HTTP on `aie_url` plus `mj compute
share` and `mj compute run`. v1 execute SHALL be
`POST {aie_url}/v1/execute` naming a host-catalog `design_id`
and bounded input bytes. It SHALL NOT be an OpenAI
chat-completions API. Mint SHALL copy the current offer
incarnation onto
`right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")`.
A caller who is not the holder and has no valid guild
delegation SHALL receive 403. Guests SHALL NOT receive
`/dev/accel` or `/dev/dri`. Overlay `aie_url` SHALL NOT be the
sole audience.

#### Scenario: Second identity runs

- GIVEN an allowlisted offering VM and a second identity in the
  grant set
- WHEN they `mj compute run` a catalog job
- THEN the client POSTs `{aie_url}/v1/execute` with that
  `design_id`
- AND the sidecar loads that catalog design after BEAM admit
- AND the guest still has no `/dev/accel`

#### Scenario: Third identity is 403

- GIVEN a third identity with no execute right and no member
  delegation
- WHEN they present execute
- THEN the response is 403
- AND the NPU program is not loaded

#### Scenario: Spawn does not mint

- GIVEN `mj spawn` of an allowlisted VM
- WHEN spawn completes
- THEN no execute token is minted
- AND no offer leaf is written by spawn

### Requirement: Guest retries a live pending_id

After enqueue returns `pending_id`, the guest or `mj` SHALL
retry that same id while the occupancy `attempt_id` is live.
After abandon, restart, cancel, or max queue age, the client
SHALL obtain a fresh nonce and enqueue again. Retries SHALL NOT
reset enqueue time.

#### Scenario: Lost reply retries the same pending_id

- GIVEN enqueue returned `pending_id` P and the occupancy
  attempt is still live
- WHEN the guest retries with P
- THEN at most one load starts
- AND a second design is not loaded

#### Scenario: Retry after abandon needs a new enqueue

- GIVEN P was abandoned (deadline, lock release, cancel, or restart)
- WHEN the guest retries P
- THEN load is not authorized
- AND a new execute requires a fresh nonce and a new `pending_id`

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
TCP to that address SHALL be INPUT. Locators in
`configure_identity` SHALL be a map. When the sidecar is up, every
boot SHALL inject `aie_url` into that map in `/etc/mjolnir/vm.json`.
When `/dev/accel/accel0` is missing or the sidecar is stopped, the
host SHALL omit `aie_url`. Omitting `aie_url` SHALL NOT remove
`api_url`, `blob_door_url`, or other sidecar locators. The sidecar
process SHALL run as a dedicated OS user with access to
`/dev/accel/accel0` and SHALL NOT run as root. That user SHALL
be a member of the dedicated AIE group that owns the admit
socket and SHALL NOT be given `/run/mjolnir/operator.sock`.

#### Scenario: Locator present on an NPU host

- GIVEN a host with `/dev/accel/accel0` and a running AIE sidecar
- WHEN a guest boots
- THEN `/etc/mjolnir/vm.json` contains `aie_url` pointing at
  `http://10.200.0.1:<aie_compute_port>`
- AND `blob_door_url` is still present
- AND locators are a map (not a positional pair of URLs)

#### Scenario: Sidecar is not root

- GIVEN a running AIE sidecar
- WHEN an operator inspects its unit user
- THEN the process is not uid 0
- AND it can open `/dev/accel/accel0`

#### Scenario: Locator absent without a device

- GIVEN a host with no `/dev/accel/accel0`
- WHEN a guest boots
- THEN `/etc/mjolnir/vm.json` has no `aie_url` key
- AND `blob_door_url` is unchanged

### Requirement: Sidecar admits on a scoped BEAM channel

The sidecar SHALL call enqueue and admission on a BEAM unix
socket at `/run/mjolnir/aie-admit.sock`. That socket SHALL be
distinct from `/run/mjolnir/operator.sock`. The operator socket
SHALL remain chmod `0600`, owner root, and SHALL remain the
full-authority operator credential. The admit listener SHALL
NOT mark the connection as operator and SHALL expose only AIE
enqueue and admission. The admit-socket credential SHALL be
mode `0660`, owner root, group `mjolnir-aie`. The configured
sidecar user SHALL be able to enqueue and admit. An unrelated
local user SHALL NOT. The sidecar identity SHALL NOT obtain
operator VM spawn, exec, kill, or snapshot routes through
either socket. After BEAM or listener restart, the admit
socket SHALL be recreated at the same path with the same mode,
owner, and group, and SHALL NOT grant operator identity.

#### Scenario: Non-root sidecar can enqueue and admit

- GIVEN the AIE sidecar running as its dedicated non-root user
  in group `mjolnir-aie` and a bound admit socket
- WHEN it calls enqueue then admission for a valid proof
- THEN both calls succeed (subject to policy and occupancy)
- AND the process is not uid 0

#### Scenario: Sidecar identity cannot use operator VM routes

- GIVEN the sidecar's OS credential (user + `mjolnir-aie` group)
- WHEN that identity calls a VM spawn, exec, kill, or snapshot
  route on the operator socket or on the admit socket
- THEN the call is refused
- AND no VM lifecycle change occurs

#### Scenario: Listener restart does not widen access

- GIVEN the admit socket bound `0660` root:`mjolnir-aie`
- WHEN the BEAM or the admit listener restarts
- THEN the socket is recreated at `/run/mjolnir/aie-admit.sock`
  with mode `0660`, owner root, group `mjolnir-aie`
- AND connections are still not operator
- AND `/run/mjolnir/operator.sock` remains `0600` root

#### Scenario: Unrelated local user cannot admit

- GIVEN the AIE-admit unix socket bound at `/run/mjolnir/aie-admit.sock`
- WHEN a local process whose uid is not the sidecar user and not
  in group `mjolnir-aie` connects
- THEN the connect is refused
- AND no enqueue or admission runs

### Requirement: Execute is a holder-checked Biscuit

Execute SHALL require a Biscuit with
`right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")` and a
holder check using the identikey-auth v1 §5 fingerprint.
`incarnation` SHALL be Blake3 of the canonical signed offer-leaf
bytes at mint. The **orchestrator BEAM** SHALL admit the request
before the sidecar loads a design: the caller proves possession of
the holder private key over a `mjolnir/aie-execute/v1`
length-prefixed frame that binds biscuit, single-use nonce,
audience (this host mint-root fingerprint), the offer resource
including incarnation, catalog design id, Blake3 of the submitted
input, and an idempotency key. The sidecar SHALL hash the job and
call enqueue then admission on `/run/mjolnir/aie-admit.sock`.
Enqueue SHALL consume the nonce once, stamp enqueue time, store
the complete verified frame, and return a `pending_id` bound
immutably to that frame and stamp. The BEAM SHALL own that
pending table. Admission SHALL name `pending_id` and the occupancy
`attempt_id` from the current try-lock, and SHALL NOT consume a
nonce. Admission SHALL refuse a missing, expired, cancelled,
already-dispatched, or unknown `pending_id`, and SHALL refuse
when the sidecar job digest or resource does not equal the
stored frame. Admission without a successful enqueue SHALL be
refused. The transition pending → dispatched SHALL be atomic,
happen at most once, and bind that `attempt_id`. Concurrent
admissions of the same `pending_id` SHALL yield one dispatch.
BEAM `dispatched` SHALL be historical status and SHALL NOT by
itself authorize an NPU load. The sidecar MAY load only while it
still holds the flock for that `attempt_id`, that attempt's
deadline has not expired, it has a live success for
`(pending_id, attempt_id)` in that window, and no load has
started for this `pending_id`. Duplicate live successes SHALL
not start a second load. After deadline expiry, lock release,
cancel, or restart, that attempt is abandoned; a retry or late
success SHALL NOT authorize a load. The same `pending_id` SHALL
NOT authorize a later occupancy attempt. Recovery after
abandonment SHALL require a fresh nonce and a new enqueue.
BEAM or sidecar restart SHALL invalidate every `pending_id`.
Cancel and max-queue-age expiry SHALL make the id unusable;
reuse SHALL be refused. Retries SHALL NOT reset enqueue time.
Overlay `aie_url` origin SHALL NOT be the sole audience. The
verifier SHALL compute the fingerprint from the proof public
key. Token-supplied `holder` facts SHALL NOT satisfy the check.
A holderless token SHALL be refused. The biscuit crate SHALL
NOT grow HTTP. The token SHALL NOT carry secret bytes. Mint of
a holder-bound token SHALL NOT require a guild identifier or a
new Datalog membership check. Mint issuer SHALL be this host's
durable production Biscuit root. Admit SHALL refuse a token
from any other issuer. The BEAM SHALL stamp enqueue time and
SHALL refuse admission after maximum queue age.

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

#### Scenario: Sidecar without BEAM admit is refused

- GIVEN a sidecar that has job bytes and a biscuit
- WHEN it has no successful admit from `/run/mjolnir/aie-admit.sock`
- THEN it SHALL NOT load a design

#### Scenario: Stale queue is refused

- GIVEN a queued job whose enqueue stamp is older than max queue age
- WHEN admission runs
- THEN execute is refused
- AND the occupancy lock is not held for that job
- AND a retry SHALL NOT reset that enqueue stamp

#### Scenario: Admission without enqueue is refused

- GIVEN a sidecar that has never received a `pending_id` from enqueue
- WHEN it calls admission
- THEN admission is refused
- AND the NPU program is not loaded

#### Scenario: Changed job or reference is refused

- GIVEN a `pending_id` bound to verified frame F
- WHEN admission names that id with a different job digest or offer
  resource than F
- THEN admission is refused
- AND the stored enqueue time is unchanged

#### Scenario: Concurrent duplicate admission dispatches once

- GIVEN a pending request that has not been dispatched
- WHEN two admission calls for that `pending_id` overlap
- THEN at most one dispatch occurs
- AND the other call fails or returns the same already-dispatched
  outcome

#### Scenario: Lost-admit-reply retry may load only on a live attempt

- GIVEN admission already transitioned `(pending_id, attempt_id)`
  to dispatched, the sidecar lost the reply, and it still holds
  the occupancy lock for that attempt within the deadline
- WHEN the sidecar retries admission with the same pair
- THEN the BEAM returns the original success
- AND the sidecar MAY start the first NPU load
- AND a second NPU load is not started

#### Scenario: Lost reply then lock release cannot load after revocation

- GIVEN admission dispatched P, the sidecar lost the reply, then
  the admit deadline expired and the occupancy lock was released,
  then the offer was withdrawn or membership removed
- WHEN the sidecar retries P or starts a later occupancy attempt
  with P
- THEN that retry does not authorize a load
- AND a fresh enqueue is refused at current-policy admission
- AND the original enqueue stamp is unchanged on P

#### Scenario: Late success after abandonment does not load

- GIVEN occupancy attempt T was abandoned (deadline, lock
  release, cancel, or restart) after admission was in flight
- WHEN a delayed success for T later arrives
- THEN the sidecar does not load
- AND historical dispatched status does not grant a new attempt

#### Scenario: Duplicate successes start at most one load

- GIVEN a live occupancy attempt that already received a success
  for `(pending_id, attempt_id)`
- WHEN a second successful admission reply for that pair arrives
- THEN at most one NPU load runs

#### Scenario: Restart invalidates pending work

- GIVEN a `pending_id` still queued
- WHEN the BEAM or the sidecar restarts
- THEN that `pending_id` is unusable
- AND admission requires a fresh client nonce and a new enqueue

#### Scenario: Expired or cancelled reference cannot be reused

- GIVEN a `pending_id` that expired by max queue age or was cancelled
- WHEN admission or a later enqueue reuses that id
- THEN it is refused
- AND a new enqueue receives a different `pending_id`

### Requirement: Sidecar serializes NPU occupancy

The sidecar SHALL use the same IRON Lab occupancy flock identity as
cooperating `ironlab` entry points. It SHALL **try-lock**, then
call BEAM admit under a hard deadline, then load or release. It
SHALL NOT hold the flock across a blocking wait for membership.
It SHALL acquire the lock immediately before catalog-design load
and SHALL release it only after the XRT worker is reaped and the
device is quiescent. A second execute while a program is loaded
SHALL wait or return busy. Timeout, cancel, and the leaf's
maximum wall time SHALL wait for quiescence before release. If
quiescence cannot be established, new execute SHALL be refused
until recovery. The lock is advisory against non-cooperating host
clients.

A v1 job SHALL be a host-catalog design id plus bounded input
bytes. The sidecar SHALL NOT load a guest-authored xclbin.

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

#### Scenario: Guest xclbin is refused

- GIVEN a caller who submits an xclbin that is not a host-catalog
  design id
- WHEN execute is presented
- THEN admit refuses
- AND the sidecar does not load it

#### Scenario: Wall time bound is enforced

- GIVEN a signed leaf with maximum wall time T
- WHEN a loaded job exceeds T
- THEN the sidecar kills the worker and waits for quiescence
- AND the occupancy lock is released only after quiescence
