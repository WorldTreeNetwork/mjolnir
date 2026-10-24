# Advise — add-lan-file-server (architecture, fable, re-read after amend)

> **ADVISE:** send-back
> **READER:** fable-5.1-arch-review
> **SPAWN:** .spawns/advise-add-lan-file-server-reread-1788538254-474109-056cfd47

Change: `add-lan-file-server` (bead `mjolnir-h2fp.2`, ACTIVE BUILD).
Rigor: architecture. Density: lean. Author family: Grok. Re-read of
the amend that closed the four owed boxes from
`reviews/2026-09-04-advise.md` and `reviews/2026-09-04-fable-advise.md`.
Both prior reviews stand untouched. Do not fold. Do not `act`. No
product code.

---

## Blind take (written before design.md / tasks.md)

From Why, `specs/lan-files/spec.md`, `blob-store` §"Door listens on
the guest overlay", `recrypt-storage-auth` source (`fingerprint.rs`,
`capability.rs`, `capability_chain.rs`), and `identikey-auth`
source (`verify.rs`, `key.rs`) plus `identikey-auth-challenge-v1.md`
§5. Raw text is in the spawn dir as `blind-take.md`.

1. **Pin:** `g = PublicKeyFingerprint::from_public_key(verified.public_key.bytes)`,
   32 raw bytes, never `Verified.fingerprint`. §5 line 146 says
   "this matches recrypt" and is a trap; the spec correctly says the
   two differ. A test must assert both fingerprints of one key are
   unequal and only `g` matches a cap.
2. **Pin:** one fixed `aud` string in config, never from `Host`,
   SNI, or bound address. One `ChallengeIssuer` and one `NonceStore`
   shared by the v4 and v6 legs.
3. **Pin:** `Capability::verify` / `verify_chain` need
   `issuer_keys_for(fp) -> VerifyingKeys`. Who is a valid issuer for
   hash `h`, and where do their keys come from? If any known issuer
   is accepted, a claimant self-issues `Capability(h → g, read)`
   and the gate is gone. The spec is silent on the issuer.
4. **Pin:** signature policy on both sides. identikey-auth
   `PqOptional` still verifies a present PQ sig; storage-auth
   `ChainPolicy` defaults to `PqRequired`. Name the policy so a
   classical-only IdentiKey is refused or accepted consistently.
5. **Refuse:** any read of door bytes without the cap check
   (`GET /files/{hash}` inherited from stock recrypt-server; a
   `blob_door_url` leak to LAN clients).
6. **Refuse:** wildcard bind when the named NIC has no address.
   Bind by interface means resolve and fail closed, not bind `*` and
   filter.
7. **Refuse:** any forward or proxy whose destination is
   `10.200.0.1:7222`.
8. **Concern:** the put path. Who may put, and what does a put
   record? A put that records nothing leaves no anchor for (3).
9. **Tradeoff I would take:** the guest learns issuer keys from
   `verify_response` (`public_key` + `pq_public_key`) at auth time,
   keyed by `g`, and the put records `g` as owner of `h`. No owner
   key in the guest; issuers become resolvable the moment they
   authenticate once.
10. **Tradeoff I would not take:** an IPv6 host proxy that
    terminates auth. It must be byte-transparent so `aud` and
    nonces are checked once, in the guest.

---

## Compare (after design.md / tasks.md / prior reviews)

The amend is right on everything it was asked to fix.

- **(1) Fingerprint map.** Answered. "Fingerprint join" names both
  namespaces, maps before the cap check, issues caps in the
  storage-auth namespace, never compares §5. Spec scenario "Cap
  permits read" now carries `g = Blake3(K)` and the negative
  assertion. Verified against `fingerprint.rs:21-25` and
  `verify.rs:21-25`. Keep.
- **(2) Fixed `aud`.** Answered. "`aud` is a service id, not a
  locator" plus the spec clause. Nonce store is shared by
  construction since both legs land in one guest process, provided
  (10) holds. Keep.
- **(5) Not stock recrypt-server.** Answered. Four deltas named;
  "patch or small guest"; no AGPL in the BEAM. Keep.
- **(6)(7) Bind by interface, fail closed, door untouched.**
  Answered. "How LAN sees it" and the "Ethernet unplugged"
  scenario mirror the door's "Dummy address missing". "Publish port
  is not 7222 on any non-TAP address." Keep.
- **(3)(8)(9) Who may issue a cap on `h`.** Not answered, and not
  covered by either prior review (neither mentions owner or
  issuer). This is the one owed item below.
- **(4) Signature policy.** Not answered. Implementer note.
- **(10) Transparent v6 proxy.** Not answered. Implementer note.

Steelman for the author: the prior send-backs asked for the
namespace map, the non-drop-in guest, the fail-closed bind, and the
fixed `aud`. All four landed cleanly and the spec scenarios are
testable. The item below is one layer under "cap-gated GET", the
same seam the fingerprint fix was on, and it was not asked before.
It is a paragraph and one scenario, not a redesign.

---

## Critical (blocks accept)

1. **The cap gate has no root of trust. As written, a self-issued
   cap reads any hash.**

   Spec, "Cap permits read": *GIVEN … a Capability for hash `h`
   granted to `g` with `read` … THEN the bytes are returned.* No
   constraint on `issuer`. Design, delta (2): "cap-gated GET using
   the mapped storage-auth fingerprint." Also no issuer.

   What the crate does and does not do:
   - `Capability::verify_full(envelope, issuer_keys, policy, perm)`
     checks signature, expiry, and permission against *whatever*
     `issuer_keys` the caller passes (`capability.rs:282-298`). It
     does not know who owns `h`.
   - `verify_chain` walks parent links and checks
     `parent.granted_to == child.issuer`, but the root cap's issuer
     is whoever signed it (`capability_chain.rs:128-160`).
   - The crate *does* ship the anchor: `OwnershipStore` with
     `register(owner, hash)` that refuses a different owner for an
     existing hash, and `is_owner` (`ownership.rs:15-35`,
     `sqlite/ownership.rs:47-95`). Stock recrypt-server registers
     ownership on PUT and checks it on DELETE, but its GET is
     public, so there is no shipped example of "GET requires a cap
     rooted at the owner". The "small guest" path in design has no
     template to copy.

   Failure: any identity that passes identikey-auth (which is
   anyone on the LAN with an IdentiKey) signs
   `Capability(subject=h, granted_to=self, issuer=self, read)`,
   presents it, and the guest, holding that identity's keys from
   `verify_response`, verifies it and serves `h`. The hash is 32
   bytes but it is a content address, shared in the clear on the
   LAN, in `.mesh` records, and in any link. Silent, like the
   fingerprint hole; the product still "works" for the owner.

   Fix (design.md, one paragraph; spec, one clause + one scenario):
   - Put is identikey-auth gated. A put records
     `ownership(h) = g_putter` via `OwnershipStore::register`.
     First putter wins; a re-put of the same bytes by a different
     `g` does not change the owner (refuse or no-op, name which).
   - GET verifies the presented cap or chain, then requires the
     **root** issuer fingerprint to equal `ownership(h)`. A cap or
     chain whose root issuer is not the recorded owner is refused
     even if every signature verifies. A cap on an `h` with no
     ownership record is refused.
   - Issuer keys are learned at identikey-auth time
     (`Verified.public_key`, `Verified.pq_public_key`) and stored
     keyed by `g`. The owner must have authenticated to this share
     at least once (they did, to put). That is the
     `issuer_keys_for` closure.
   - Spec: requirement "Data access is recrypt-storage-auth" gains
     "AND the capability's root issuer is the owner recorded at
     put". Add scenario "Cap issued by non-owner": GIVEN a verified
     identity `g2 ≠ owner(h)` AND a valid Capability for `h`
     granted to `g2` and issued by `g2` … THEN it is refused AND
     the bytes are not returned.

---

## Implementer notes for `h2fp.3` (not boxes)

- **Signature policy.** `ChainPolicy::default()` is `PqRequired`;
  `Verified.pq_public_key` is `Option`. Pick one policy for the
  share and apply it to both `verify_response` and cap
  verification. If `PqRequired`, a classical-only IdentiKey can
  neither put nor issue; say so at the door, not at GET time.
- **Classical alg guard.** `ClassicalPublicKey { alg, bytes }`.
  Map to `g` only when `alg` is Ed25519; refuse otherwise. Do not
  Blake3 a non-Ed25519 key into the storage-auth namespace.
- **v6 proxy is L4 and byte-transparent.** Auth, `aud`, and
  nonces are checked in the guest only. If the proxy is L7 it must
  not rewrite the challenge body and must not terminate auth.
- **Ownership store is guest state.** Same durability class as
  caps and the index (design delta 4). If the ownership table is
  lost the anchor above is lost; a fresh guest with an empty
  ownership table refuses every GET, which is the correct failure.
- **Door dedup vs ownership.** The door is content-addressed and
  unauthenticated from the guest's side; two putters of the same
  bytes share one door object. Ownership is the guest's index, not
  the door's. Do not delete the door object on the owner's
  unregister if another owner record could exist (it cannot under
  first-putter-wins, so this is a one-line comment, not logic).

---

## Verdict

Send-back. The four prior owed boxes are closed correctly and
should not be reopened. One new owed box: pin the cap root of
trust to the owner recorded at put, with issuer keys learned at
auth time, and add the "Cap issued by non-owner" scenario. Nothing
else in this review gates. Close that box and this reader accepts
without another blind pass.
