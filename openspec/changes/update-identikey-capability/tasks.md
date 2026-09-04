# Tasks

Architecture artifacts for `update-identikey-capability`. Copying
into the protocol spec is `act` after advise accept. Grok authored;
advise reader must not be Grok (ADR-005). Fable 5 is the
cross-family reader. Sol is not subscribed.

- [x] Write `design.md` (decisions)
- [x] Delta `specs/identikey-capability/spec.md` (ADDED)
- [x] Advise accept-with-nits (Fable) —
      `reviews/2026-08-26-fable-advise.md`. Nits are fold/act
      notes, not spec-text. Cross-family accept (ADR-005).
- [x] Send-back 2026-08-26: holder SHALL scoped to secret-redemption
      profile; `holder(<fingerprint>)`
- [x] Send-back 2026-08-26: hops optional for v1 redeem
- [x] Send-back 2026-08-26: v1 hop = nextKey; Identikey = third-party
      later
- [x] Send-back 2026-08-26: fingerprint encoding (auth-challenge §5)
- [x] Human amend 2026-08-26: salted Blake3 commitments; unsalted
      secret hashes forbidden; Gordian elision deferred
- [x] ASK: second-family advise —
      `reviews/2026-09-04-advise.md` (oh-my-claudecode-critic;
      Fable 5.1 / opus-4.8 / Sol were infra-red; this is the
      other-family accept). No owed boxes.
- [ ] Send-back 2026-09-04 (Fable 5.1,
      `reviews/2026-09-04-fable-advise.md` F1): bind copy-out to
      the holder, not only the proof. Holder proof SHALL include
      and sign over a recipient public encryption key; copy-out
      SHALL be sealed to it (HPKE, X25519 or P-256). Or add a
      Rejected line stating the threat model that makes a
      delegated signature out of scope. Spec delta + Decision 3.
- [ ] Send-back 2026-09-04 (Fable 5.1, F2): verifier SHALL reject
      a redeem token that binds no holder (absent check ≠ failed
      proof). One sentence in the holder-bound SHALL; suggested
      `bound_holder(<fp>)` in authority + authorizer policy.
- [ ] After accept: `act` fold the ADDED requirements into
      `identikey-protocol/docs/standards/identikey-capability-v1.md`
      (new sections; keep three-layer table; point tokenator at
      `add-secret-tokenator`)
- [ ] After accept: `act` one-line on protocol `docs/standards/README.md`
      if the table blurb needs the holder/redeem sentence

Handoffs (not checkboxes):

- `add-secret-tokenator` (`mjolnir-axsb.1.2`) — host verifier
- `add-biscuit-runtime` (`mjolnir-axsb.1.3`) — mint/verify code
- Guild holder class — named in Decision 5, not built
- `ikp-6yz.2` — test vectors
