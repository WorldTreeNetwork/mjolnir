## ADDED Requirements

### Requirement: Guild-scoped offers inject membership

When the **current** verified offer names a guild or Recrypt
keyspace, execute SHALL succeed only if BEAM guild admission
returns `:ok` for that occupancy attempt. The holder proof key
SHALL be the consumer VM IdentiKey. A human member key SHALL
NOT be required inside the guest. Enqueue-time membership or
delegation SHALL NOT authorize admission. A personal-fp offer
SHALL NOT require lookup or delegation. The Biscuit authority
block and `Biscuit.authorize/6` SHALL NOT gain a membership
fact or Datalog check. Token-authored `member` facts SHALL NOT
count.

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
