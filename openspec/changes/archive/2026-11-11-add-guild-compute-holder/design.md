# Design

Implements ADR 0015 Decision 6. Does not reopen guilds-in-v1
(that fork is closed on the parent).

## Decision — Inject, not Datalog mint

`mint` / `authorize` stay one fingerprint plus `inject_holder`
(`lib/mjolnir/biscuit.ex:198–215`). The crate has no `member`
inject. Guild membership is **not** a Datalog fact inside
`authorize`. It is a BEAM application gate (Decision — Admit
API) that uses a trusted roster lookup plus a member-signed
delegation leaf. A token that asserts `member` still fails
that gate. identikey-capability "Guild holder class is not v1"
is unchanged.

## Decision — Delegation leaf (R1)

Profile `mjolnir/aie-delegate/v1`. Signing bytes follow the
Redeem grammar (`lib/mjolnir/secrets/redeem.ex:121–124`):
unprefixed domain then unsigned-big-32 length-prefixed fields
in this order:

1. version — 4-byte unsigned-big-32, value `1`
2. guild/keyspace id — UTF-8
3. member Ed25519 pubkey — 32 raw bytes
4. consumer-holder fingerprint — 32 raw identikey-auth v1 §5
   bytes
5. purpose — `aie-execute`
6. issued-at — 8-byte unsigned-big-64 unix seconds
7. expires-at — 8-byte unsigned-big-64 unix seconds
8. sequence — 8-byte unsigned-big-64, strictly increasing per
   `(member, holder)`

The member Ed25519-signs those signing bytes.

Deterministic vector (unsigned): domain
`mjolnir/aie-delegate/v1`, version 1, guild `g1`, member_pk 32
zero bytes, holder_fp 32 zero bytes, purpose `aie-execute`,
issued-at 0, expires-at 86400, sequence 1. Signing bytes hex
(160 bytes):

`6d6a6f6c6e69722f6169652d64656c65676174652f763100000004000000010000000267310000002000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000b6169652d65786563757465000000080000000000000000000000080000000000015180000000080000000000000001`

Validity: `issued-at <= now+5s`, `expires-at > now`,
`expires-at - issued-at <= 86400`. Equality at `expires-at`
is expired.

v1 consent is **guild-wide** for AIE execute: a valid leaf for
guild G and holder H authorizes H on every current offer that
names G. A leaf for G1 SHALL NOT satisfy an offer that names G2.

Identity comparisons: lookup `member_pk` SHALL equal the leaf's
member pubkey; leaf holder fp SHALL equal the proven request
holder fp (same §5 namespace). Wrong member, wrong holder, bad
signature, wrong purpose, or cross-guild use is refused.

## Decision — Selector (R4)

`Guild.admit/1` does not search. The execute frame (stored on
the pending row at enqueue) SHALL include `member_pk` as an
**untrusted selector**. Admit reads it from the pending table
via `pending_id`. Missing selector refuses. The selector SHALL
NOT establish membership or signer identity: roster
`lookup(G, member_pk)` and the leaf signature still must match.
Multiple members who delegated to H: the guest names which one.

Store owner derivation: SecretStore identikey_fp is
`Mjolnir.Sites.IdentiKey.fingerprint/1` of `member_pk` (base58
Blake3 of raw pubkey). That is the **storage** namespace.
Protocol comparisons stay §5. `member_fp` in the store path is
the storage fp. The leaf field is 32-byte §5 of the consumer
holder. Mapping: same 32-byte `member_pk` → storage fp for the
path, and roster/leaf compare raw `member_pk`.

## Decision — SecretStore codec (R5)

This node owns a registered SecretStore record type
`aie_delegate`. Envelope JSON includes `type`, the profile
fields (base64 for raw keys), `sequence`, and
`signature.ed25519`. `canonical_bytes_without_sig/2` SHALL
recognize it (`lib/mjolnir/secret_store.ex:711–735` today
sniffs Head/Manifest/Alias only). Canonical signing bytes of
the envelope SHALL equal the profile signing bytes above, so
one member signature covers store put and admission verify.
Owner-key registration is the existing `identity/pubkey`
record under the storage fp. Wrong-namespace put (storage fp
≠ fingerprint of embedded member_pk) is refused.

Current leaf key: `(storage_fp, "aie/delegate/<holder_fp58>")`
where `holder_fp58` is base58 of the 32-byte §5 holder fp
(path-safe). Admission reads that key after resolving
storage_fp from the selector `member_pk`.

## Decision — Withdrawal profile (R7)

Withdrawal is a distinct profile
`mjolnir/aie-delegate-withdraw/v1`, same Redeem grammar as
the grant, purpose `aie-withdraw`. Fields: version u32be `1`,
guild UTF-8, member_pk 32, holder_fp 32, purpose
`aie-withdraw`, issued-at u64be, expires-at u64be (`0` =
durable), sequence u64be. The member signs those bytes.
A live-grant signature (`aie-execute` / grant domain) SHALL
NOT authorize withdrawal. A withdraw signature SHALL NOT be
interpreted as a live grant. Target is `(member, holder)`;
wrong-target withdraw is refused. Sequence N withdraws every
grant at sequence ≤ N for that pair. After a later regrant at
M > N, a tombstone at sequence ≤ N SHALL NOT withdraw M.

Deterministic unsigned vector: domain
`mjolnir/aie-delegate-withdraw/v1`, version 1, guild `g1`,
32-zero member_pk and holder_fp, purpose `aie-withdraw`,
issued-at 0, expires-at 0, sequence 1. Signing bytes hex
(170 bytes):

`6d6a6f6c6e69722f6169652d64656c65676174652d77697468647261772f763100000004000000010000000267310000002000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000c6169652d7769746864726177000000080000000000000000000000080000000000000000000000080000000000000001`

## Decision — Single authoritative record (R6/R8)

One SecretStore key
`(storage_fp, "aie/delegate/<holder_fp58>")` holds the current
record: either an `aie_delegate` grant or an
`aie_delegate_withdraw` tombstone, never both. Sequence of
that record is the floor. Mutations are `put` of a complete
envelope with sequence > current sequence (missing key treats
floor as 0). Atomic rename of that one file is the commit
point; admission reads one snapshot. No second floor file.

Partial/corrupt/unreadable/malformed current bytes fail
closed (refuse guild admit). A grant snapshot authorizes only
if type is grant, sequence equals the record sequence, and
grant checks pass. A tombstone snapshot never authorizes.
Concurrent admission vs mutation: one complete snapshot; a
job admitted on grant N before tombstone N+1 commits may
finish (parent loaded-job policy). Generic
`SecretStore.delete/3` and any put that is not this codec
SHALL NOT mutate this key. Floor-reset (delete then put
sequence 1) is refused: delete is not allowed; put sequence 1
after tombstone N is sequence ≤ floor.

Only the member whose registered pubkey verifies the envelope
MAY put. Intentional regrant is a **new** grant envelope with
sequence > current (including after tombstone) and new
issued-at/expires-at. Restart sees the last complete record.

## Decision — Roster adapter (R2)

`Mjolnir.Aie.Guild.Roster` is the adapter. Host config maps
each guild/keyspace id to `{endpoint, authority_pubkey}`. An
unconfigured guild fails closed. A stub that returns member is
not a trusted lookup.

`lookup(ks, member_pk)` returns
`{:ok, %{member?: boolean, issued_at: unix}}` only when the
response is authenticated by that guild's configured
authority and bound to the queried `(ks, member_pk)`.
Otherwise `{:error, :unauthenticated | :malformed | :wrong_subject | :unavailable | :stale | :future}`.

`issued-at` is unix seconds. Provider max-age is finite host
policy (default 60s). Future skew max 5s. Admission deadline
is the occupancy attempt deadline. Timeout and unavailability
fail closed. A fresh negative overrides an older still-within-
TTL positive. The adapter attests **membership only**. Current
delegation is the SecretStore leaf (R1), not the roster body.

This repo has no Recrypt membership HTTP yet. The adapter
contract is this node; a production Recrypt roster is a later
wiring behind the same callback. Until an authority is
configured for G, guild-scoped offers that name G refuse.

## Decision — BEAM admit API (R3)

`add-aie-host-sidecar` calls `Mjolnir.Aie.Guild.admit/1` at
admission after a successful try-lock, never `Biscuit.authorize`
for membership. Inputs: verified current offer (personal vs
guild/ks id), proven consumer holder fp, `pending_id` (pending
row includes untrusted `member_pk` selector), `attempt_id`,
deadline. Output: `:ok | {:error, reason}`.

Conjunction for a guild-scoped offer: valid execute proof AND
valid Biscuit right/incarnation/holder AND current roster
membership AND current valid delegation for that holder.
Personal-fp offers skip only the guild portion. A result for
an abandoned `attempt_id` SHALL NOT authorize a later attempt.
Missing this gate on a guild-scoped offer SHALL NOT load.

## Decision — Admission-time freshness

Lookup and current-leaf read run after a successful occupancy
try-lock, under that attempt's deadline. Enqueue-time
membership or delegation SHALL NOT authorize admission.

## ADR 0015 one screen (guild clause only)

Holder = consumer VM; guild = injected member plus member-signed
delegation. Revalidate at each successful try-lock.
