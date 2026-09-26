# Design — edge operational keys

**Status:** Proposed. ACTIVE BUILD. Revised 2026-09-24 after astra-arch-review advise-4.
**Change:** `add-edge-op-keys`
**Bead:** `mjolnir-22ff.2`
**ADR:** `docs/decisions/0012-direct-edge-auth.md` (this change writes it)

## Problem

Hosted OIDC makes `auth.identikey.me` the trust root. Direct auth
inverts that: the edge is the authenticator. Without a stable edge
identity and rotating online keys, every session either needs a
hosted OP or puts a long-lived key on the hot path.

## Decision 1 — Two keys, one pin

The client pins the **stable edge XID**. That XID's identity key
delegates to **operational keys** that:

- prove the edge on the challenge (audience is the pinned XID)
- mint capabilities (`add-biscuit-profiles` / later endpoints)

The stable key is not required online for ordinary sessions.
Hardware wrap is later.

## Decision 2 — Host files, not the data volume

`/var/lib/mjolnir/auth`, `0600`, same exclusion as escrow and blob
cache. A named snapshot or `@vms/` clone must not copy these bytes.

## Decision 3 — Discovery is not TOFU

Lightning `.mesh`, Babel, and Iroh supply a reachable address. They
do not name the key. First login without a pin fails closed.

## Decision 4 — Rotation overlap

Op keys carry key IDs. Unexpired capabilities signed by the previous
op key verify until they expire or are revoked. A rotation that
drops the old key immediately would invalidate live sessions;
overlap is the default. Compromise path is: revoke/supersede the
stolen op key, keep the stable XID.

## Decision 5 — Delegation contract (R1)

The pin is a 64-hex XID whose identity public key is Ed25519
(identikey-auth v1). An operational key is authorized only by a
delegation signed by that identity key over: operational public
(Ed25519), key id, edge XID, purposes `{edge-proof, cap-mint}`,
`nbf`/`exp`, and “no onward delegation”. A key id is a selector, not
authority. Verifier inputs: pin XID, identity public, delegation
bytes, operational public. Reject: wrong edge XID, tampered
delegation, purpose not in the set, outside `[nbf,exp]`, substituted
public with a reused key id. Edge-proof and cap-mint may share the
op key; signed-message domains stay distinct (challenge vs biscuit
root).

## Decision 6 — Generation is not activation (R2)

First provision: operator (or bootstrap) writes the stable identity
and signs the first op-key delegation. Restart with valid delegation
on disk does not need the stable private. “Mint on start if missing”
applies only when **no** established op-key state exists **and** the
stable private is available to sign a delegation; otherwise missing
or corrupt op-key state fails closed for **direct** auth. Hosted JWT
verification (`add-offline-jwks`) remains available. Silent
replacement of the stable XID is forbidden.

## Decision 7 — Overlap and revocation bounds (R3)

Delegation `exp` bounds that op key’s authority, independent of
capability `exp`. Issuing K2 does not by itself invalidate a still-valid
K1 delegation. Graceful overlap = both delegations unexpired. Retirement
= new delegation that supersedes K1 (signed by the stable key) or K1
`exp` elapses. Offline verifiers learn supersession only from updated
delegation material they fetch or are given; a stale verifier may
accept a newly forged K1 capability until its local K1 delegation
expires — that exposure is bounded by delegation `exp`, not capability
`exp`. Numeric defaults remain deferred; the bound exists. Compromise:
operator signs a supersession with `exp=now` for K1 when the stable
private is available; if it is not, wait out K1 delegation `exp` and
restore the auth dir from backup that already contains the
supersession.

## Decision 8 — Persist and restore (R4)

Directory `0700`, private files `0600` at creation **and at every
open**. Opening an existing private file whose mode is not `0600`
or a directory whose mode is not `0700` fails closed for direct
auth. Tmp files in the same dir. Reject paths/aliases under
`btrfs_root`. Activation of {private op key, matching delegation,
current-kid metadata} is atomic (tmp+fsync+rename of a bundle).
Interrupted rotation recovers the previous bundle or fails closed;
a revocation that was already durable MUST still be present after
that recovery. Backup is a copy of the auth dir off-box. Restore of
the same stable XID must not revive a superseded kid as current.
Root loss without backup is a new edge identity (new pin), not a
silent remint of the old XID. Host compromise exposes online op
keys; that is accepted for v1 (same posture as escrow).

## Decision 9 — Residual after advise-2

XID-to-key: the pin equals the Gordian XID of a document whose
inception public is the Ed25519 identity key. A document that merely
labels itself with a victim XID without that inception public fails.
Delegation bytes are identikey-auth over
`["identikey-mjolnir/v1","op-delegation", op_pub, kid, edge_xid,
purposes, nbf, exp, no_onward]`.

Supersession is **only** the identity-key identikey-auth signature
over dCBOR
`["identikey-mjolnir/v1","op-supersede", kid, exp_now, next_kid]`.
There is no second “same-domain supersedes=” encoding. `kid` is the
revoked operational key. `exp_now` is the **effective revocation
time** of that kid (unix seconds), not the expiry of the
supersession record. A verifier that first receives a valid
supersession after `exp_now` SHALL still honor it (late receipt).
The record remains authoritative at least until that kid’s original
delegation `exp` elapses; after that the grant is expired anyway.
`next_kid` **names** a successor that MUST have its own
`op-delegation`; the supersession does not authorize the successor.
Durable file outranks a replayed older grant after restart.
Capability `exp` cannot exceed the signing key’s delegation `exp`.
K1→K2→K3 keeps public verification material for every kid whose
delegation `exp` has not passed **and** that has not been
superseded; unrevoked K1 remains valid across later rotations.

Stale backup: a restored bundle is **reconciliation input**, not
live authority. Activation requires a **fresh** operator restore
ceremony, not a reusable old signature. The operator attests the
**reconciled output** with the identity key over
`["identikey-mjolnir/v1","auth-restore", bundle_hash, restore_id,
observed_revocations_hash, issued_at]`. `restore_id` is unique per
ceremony. `bundle_hash` covers the public verification state being
activated: identity public, XID, delegations, supersessions,
current-kid (not private key bytes). `observed_revocations_hash`
covers the operator-confirmed supersession set that MUST be merged
into that output. Evidence retained **outside** the backup: a
current supersession/revocation list (operator notes or a second
off-box copy of the latest log). An old attestation `A1` for backup
`B1` SHALL NOT activate `B1` after a later supersession was
learned. If the operator cannot establish current revocations,
direct auth for that XID fails closed. Waiting out a kid’s
delegation `exp` removes that kid; it does not authorize a
successor. Interrupted activation after a revocation was durable
recovers a bundle that still contains that revocation, or fails
closed.

Root **compromise** (stable private leaked): the old pin is retired.
v1 does not have an independent recovery committee — mint a **new**
identity and distribute a new pin. Stolen-root + attacker
delegation for the old XID is rejected once clients are updated to
the new pin; until then clients that still pin the old XID are
compromised (that is the pin model). Operational-key compromise
alone is supersede. Root **loss** without leak is restore-from-backup
with a **fresh** recovery attestation of the reconciled output,
same pin.
