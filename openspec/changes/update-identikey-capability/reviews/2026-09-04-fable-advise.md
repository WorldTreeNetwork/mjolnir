# Advise — update-identikey-capability (architecture, Fable 5.1 read)

> **ADVISE:** send-back
> **READER:** fable-5.1-arch-review
> **SPAWN:** /home/dorje/work/IdentiKey/mjolnir/.spawns/advise-update-identikey-capability-fable-1788535585-453936-5b57a6fb

Designated architecture reader (ADR-005, author family Grok). This
is the 2026-09-04 read that `tasks.md` recorded as infra-red;
`reviews/2026-09-04-advise.md` (oh-my-claudecode-critic) is the
other-family accept and is left untouched. Prior Fable read:
`reviews/2026-08-26-fable-advise.md` (accept-with-nits). Rigor:
architecture. No product code. Banner not flipped.

Scope: Why, `specs/identikey-capability/spec.md`,
`lib/mjolnir/secret_store.ex` `put_opaque/4`,
`docs/plans/rbac-design.md`, `identikey-capability-v1.md`,
auth-challenge v1 §5, Recrypt D-5 §0–§1 (blind pass); then
`design.md`, `tasks.md`, `proposal.md`, both prior reviews, and
consumer `add-secret-tokenator/{design,specs}` (compare pass).

## Blind pass (before design.md / tasks.md)

1. Pin: the binding must be a `check` in the authority block
   against a verifier-injected fact. "The Datalog fact SHALL be
   `holder(fp)`" reads as a fact, and a fact the minter emits
   would satisfy the check with no proof. Say check vs fact.
2. Pin: the signed material needs audience and token identity, not
   just nonce. The SHALL says nonce + token identity; the scenario
   says nonce + audience. Define "token identity".
3. Pin: a holder proof shows Z *participated*, not that Z
   *receives*. An intermediary that gets one signature out of Z
   collects the PAT itself. Copy-out must be sealed to a key Z
   controls, or the channel must terminate in Z.
4. Pin: say the D-5 concession out loud. The tokenator holds the
   PAT in plaintext at rest (`put_opaque`, 0600 file) and learns
   every redemption. What is kept is authority-in-token, no role
   registry.
5. Pin: "a hop cannot widen or unbind" leans on Biscuit v2+
   block-scoped facts. Name the version the fold assumes.
6. Refuse: any return path that hands PAT bytes to the presenter in
   the clear when the presenter is not provably the holder.
7. Refuse: `Blake3(secret)`; also plain `domain||salt||secret`
   without length framing. Blake3 keyed / derive_key is the
   idiomatic salted form.
8. Nit: secret rotation vs commitment. Bind on id; digest optional.
9. Tradeoff: single-key holder means every redeemer owns an
   in-guest Identikey and redeem is a two-round-trip flow. Fine.
10. Tradeoff: nextKey hops give monotonicity only; "provenance"
    oversells. Acceptable if the fold keeps saying so.

## Compare and steelman

Design answers 1, 2 (partly), 5 (implicitly), 7–10.

- **(1) check vs fact.** Decision 3 writes it as
  `check if holder($fp), $fp == "<fp>"` with the verifier
  injecting the fact. Answered in design; the spec delta still
  says "fact". Fold note, not a round: copy the check form into
  the SHALL.
- **(2) token identity.** Decision 3 signs
  `(biscuit hash, nonce, audience)`; consumer Decision 3 gives the
  wire. Both prior reads flagged the SHALL/scenario mismatch as a
  fold note. I concur and do not re-litigate.
- **(4) D-5 concession.** Consumer Decision 4 states it exactly
  ("This service learns that Z redeemed secret S at time T, and it
  handles PAT bytes... It applies, and we take it"). Protocol
  design only says "honest availability dependency". Fold note:
  one sentence in the protocol profile so a second implementer
  does not read the tokenator as registry-free.
- **(5) Biscuit version.** Neither design nor spec names it. Fold
  note.
- **(7) framing.** Consumer pins the domain string. Framing is an
  `ikp-6yz.2` vector concern. Nit.
- **(3) delivery.** Not answered anywhere. This is the send-back.

Steelman for accepting as written: the proof already binds
`biscuit_hash`, `nonce`, `aud`; the nonce is single-use; Z's
redeem client fetches its own challenge and signs nothing it did
not fetch; so an intermediary cannot obtain a usable signature.
That holds only if Z's signing surface is disciplined, and Z is
by construction an agent VM whose parent shapes its inputs. The
Why's invariant is "a working secret must not travel down an
agent tree". A design that makes that invariant depend on a
subordinate LLM agent declining to sign a challenge its parent
handed it has moved the control from the protocol to the client.
The protocol should not need that assumption.

## Findings

### F1 (send-back) — Copy-out is not bound to the holder, only the proof is

`spec.md` "Foreign-secret redemption is agency, not PRE", scenario
"PAT is the example foreign secret": *"the tokenator may return
the PAT to Z AND intermediate agents who only forwarded the
Biscuit do not receive it."* The mechanism specified (Decision 3;
consumer Decision 3 steps 3–4) is: presenter POSTs
`{biscuit, alg, public_key, signature, nonce}`; host verifies,
injects `holder(fp)`, evaluates, returns `{value, salt}` **to the
presenter**. The signature is detached and portable. Nothing
ties the response to Z.

Concrete: C (a forwarder) fetches a challenge, passes
`{biscuit_hash, nonce, aud}` to Z, Z signs, C POSTs, C receives
the PAT. Z never sees the tokenator. The holder proof was
satisfied. The SHALL text ("intermediate agents... do not receive
it") is violated by a conforming implementation.

This is the profile's whole reason to exist, so it belongs in the
protocol delta, not only in the consumer. Fix is small and
transport-independent: the holder proof SHALL include (and sign
over) a recipient public encryption key, and copy-out SHALL be
sealed to that key (HPKE, RFC 9180, DHKEM X25519 or P-256 so
enclave holders work). The key MAY be ephemeral and generated
in-guest. That is the D-5 §0 substrate shape verbatim ("a keypair
was generated in-guest, here is the public half, deliver this
blob to it"), so it is vocabulary IdentiKey already owns. After
this, a stolen signature buys the intermediary a ciphertext it
cannot open.

The author may instead reject sealing with a stated threat-model
line (e.g. "a holder that signs redeem challenges it did not
fetch is compromised; out of scope"). I would still not accept
that line, because it makes the Why's invariant a client
property. But it is the honest alternative and the owed box
allows either.

### F2 (send-back, one sentence) — Absent binding is not a failed proof

`spec.md` fails closed on "a failed holder proof". A redeem token
whose authority block carries `right(S, "redeem")` but no holder
check evaluates clean after the verifier injects `holder(fp)`.
Possession is then sufficient, which the same requirement forbids,
but the specified mechanism ("inject, then evaluate") does not
detect it. Mint bugs and profile drift (a VM-exec profile token
that also names a secret) become bearer PAT tokens.

Owed: the verifier SHALL reject a redeem when the token does not
bind a holder. Cheapest form: authority block SHALL carry
`bound_holder(<fp>)` alongside the check, and the authorizer
policy SHALL require `holder($p), bound_holder($p)` from the
authority block. Biscuit v2+ scoping keeps appended blocks from
supplying `bound_holder`.

### Fold notes (not owed boxes)

- Copy Decision 3's `check if holder($fp), $fp == "<fp>"` into the
  SHALL; the delta currently says "fact".
- Copy the signed tuple `(biscuit_hash, nonce, aud)` into the
  SHALL so requirement and scenario match (both prior reads).
- Add the D-5 concession sentence from consumer Decision 4 to the
  protocol profile.
- Name Biscuit v2+ block scoping as the assumption behind "a hop
  SHALL NOT remove holder checks or widen rights".
- Keep the "monotonicity, not attribution" sentence next to the
  "hop provenance" title at fold (prior reads agree).

## What is solid

Three layers stand; tokenator-as-verifier is the right frame and
the PRE-of-PAT rejection is correct. Profile-scoped holder SHALL
with the explicit VM-exec carve-out is the precise fix to the
08-26 send-back. Zero-hop redeem plus nextKey-only hops is the
honest v1 cut. Salted Blake3 commitment and the Blake3-of-dCBOR
fingerprint (not the SHA-256 stub, not raw Ed25519) are pinned
where they need to be. Guilds named, not built.

## Verdict

Send-back on F1, with F2 riding the same round. Both are
one-to-three sentences in `specs/identikey-capability/spec.md`
plus a Decision 3 paragraph. No change to direction. Once the
boxes close, the fold into `identikey-capability-v1.md` can
proceed as the other-family read describes.
