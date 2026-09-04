# Advise — update-identikey-capability (architecture, Fable 5.1 reread after amend)

> **ADVISE:** accept
> **READER:** fable-5.1-arch-review
> **SPAWN:** /home/dorje/work/IdentiKey/mjolnir/.spawns/advise-update-identikey-capability-reread-1788538254-474111-7c50c086

Reread of the send-back amend (commit `f2c6955`, "seal copy-out to
holder; reject unbound redeem"). Author family Grok; this is the
cross-family reader (ADR-005). Prior reads left untouched:
`2026-09-04-fable-advise.md` (send-back F1/F2),
`2026-09-04-advise.md` (critic accept), both 08-26 reads. Rigor:
architecture. No product code. Banner not flipped.

Scope: Why, `specs/identikey-capability/spec.md`,
`lib/mjolnir/secret_store.ex:155` `put_opaque/4`,
`docs/plans/rbac-design.md` (blind pass); then `design.md`
Decision 3, `tasks.md`, `proposal.md`, the amend diff, the prior
reviews, and consumer `add-secret-tokenator/design.md` Decision 3
(compare pass).

## Blind pass (before design.md / tasks.md)

1. PIN: the "unbound redeem is rejected" rule must live in the
   authorizer, not the token. The tokenator policy itself asserts
   `check if right($s,"redeem"), bound_holder($p), holder($p)` over
   authority-block facts only.
2. PIN: the holder-proof payload needs a domain tag and canonical,
   length-prefixed encoding of (biscuit_hash, nonce, audience,
   recipient_pk). Biscuit hash is over the full token as presented,
   not block 0, so the proof binds to exactly the bytes evaluated.
3. PIN: nonce is verifier-issued, single-use, short TTL; audience is
   the tokenator's own identity and is checked equal to self.
4. PIN: the intermediary scenario holds only if Z never signs over a
   recipient key it does not control. Derive from the identity key
   where possible (X25519 from Ed25519) or make "refuse to sign over
   a caller-supplied recipient key" a holder-client MUST. P-256
   enclave identities cannot derive, so the client rule is the floor.
5. PIN: HPKE suite fixed by name; `info` = domain || biscuit_hash ||
   nonce; AAD = the salted commitment, so the recipient verifies the
   plaintext against the commitment after opening.
6. REFUSE: a hand-rolled box in Elixir. Vetted HPKE only (Rust
   `hpke` via NIF, or the recrypt stack). Tradeoff: one more NIF
   surface; a homegrown seal is worse than none.
7. REFUSE: localhost auth bypass substituting for the holder proof
   on redeem. Bypass grants scopes; it must not manufacture
   `holder()`.
8. PIN: fingerprint-from-`{alg,key}` is one shared function with
   auth-challenge v1 §5. No second Blake3 fingerprint impl.
9. PIN: secret + salt via `put_opaque` in a kind namespace distinct
   from VM material; commitment computed at put time; copy-out
   returns commitment + salt beside the ciphertext.
10. TRADEOFF: single-use nonce tracking is in-memory (ETS, TTL); a
    restart forgets consumed nonces inside the window. Accept with
    a short TTL; no persistence in v1.

## Compare and steelman

Amend closes both owed boxes exactly as owed.

- **F1 (seal to holder).** SHALL now signs over
  `(biscuit hash, nonce, audience, recipient public encryption
  key)`, seals copy-out with HPKE, and fails a signature that does
  not cover the key. Decision 3 step 5 names RFC 9180, DHKEM
  X25519 or P-256, key MAY be ephemeral and in-guest. New scenario
  "Intermediary collects a delegated signature" is the F1 attack
  written as a test. Closed.
- **F2 (unbound reject).** Authority block SHALL carry
  `bound_holder(<fp>)` next to the check; authorizer SHALL require
  `holder($p), bound_holder($p)` from the authority block; "absent
  check is not a failed proof" is in Decision 3 step 4; new
  scenario "Redeem token with no holder binding". Closed. Matches
  blind item 1.
- **Blind 3, 8, 9, 10** answered by Decision 3 step 1, the
  fingerprint sentence, and the consumer's vault layout. Blind 6
  and 7 are consumer/runtime concerns, not protocol text.
- **Blind 2 and 5** (framing, HPKE `info`/AAD) are wire detail.
  Prior read already routed framing to `ikp-6yz.2`. Not owed here.
- **Blind 4** is the residual. The SHALL says "recipient public
  encryption key" unqualified; the Named-key scenario says "Z's".
  If Z's redeem client will sign over a recipient key handed to it
  by C, C opens the seal and the intermediary scenario is false.
  Steelman for accepting as written: the recipient key is
  something Z generates, not something Z receives. A nonce is
  opaque verifier randomness Z cannot vet; a recipient key is Z's
  own output. An honest client has no code path that signs over a
  foreign key. The assumption moved from "Z declines a challenge
  it cannot distinguish" to "Z does not expose a signing oracle
  over a caller-chosen key", which is a shape property of the
  client API, one clause to pin, and no longer a load-bearing
  discipline. I take the steelman. One qualifying clause at fold
  (below), not a round.

## Findings

No owed boxes.

## Fold notes (not owed)

- **Qualify the recipient key.** In the SHALL: "a recipient public
  encryption key the holder controls (MAY be ephemeral, generated
  in-guest). A holder SHALL NOT sign a redeem proof over a
  recipient key supplied by another party." Optional strengthening
  for Ed25519 holders: recipient key SHOULD be the X25519 image of
  the identity key and the verifier MAY check it. P-256 holders
  cannot, so it stays SHOULD/MAY.
- **Copy-out authenticity through an intermediary.** HPKE base
  mode gives Z confidentiality, not proof the ciphertext came from
  the tokenator. If the token carries no digest, C can hand Z a
  seal of the wrong secret. Denial, not leak. Cheapest fix: make
  the salted commitment mandatory on the redeem profile (it is
  MAY today), or HPKE auth mode with the tokenator's key. Author's
  call at fold.
- **HPKE wire for the consumer.** Suite by name; `info` = domain ||
  biscuit_hash || nonce; AAD = commitment || salt. Vetted library
  only. Route to `add-secret-tokenator` / `add-biscuit-runtime`.
- **Consumer drift.** `add-secret-tokenator/design.md` Decision 3
  still signs `{biscuit_hash, nonce, aud}` and returns
  `{value, salt}` in the clear. That is now non-conforming to this
  delta. Its own send-back round is open (backup path, freeze
  sink); the recipient-key + HPKE + `bound_holder` authorizer
  policy should ride that same amend. Conductor: route.
- Carry-overs from the prior read, still fold notes: name Biscuit
  v2+ block scoping under "a hop SHALL NOT remove holder checks";
  add the D-5 concession sentence (tokenator learns every
  redemption, holds plaintext at rest) to the protocol profile;
  domain tag + canonical framing of the signed tuple and "biscuit
  hash = Blake3 of the full serialized token" to `ikp-6yz.2`.

## What is solid

Three layers stand; tokenator-as-verifier; PRE-of-PAT rejected.
Holder SHALL scoped to the redeem profile with the VM-exec
carve-out. Zero-hop redeem, nextKey-only hops, third-party blocks
deferred. Salted Blake3 commitment, Blake3-of-dCBOR fingerprint.
Bearer-plus-holder-plus-sealed-delivery now names the D-5 §0
substrate shape, which is the right vocabulary. Guilds named, not
built.

## Verdict

Accept. Both 2026-09-04 owed boxes are closed in the delta and in
Decision 3. The remaining items are fold clauses and a consumer
handoff, none of which changes direction. The `act` fold into
`identikey-capability-v1.md` may proceed.
