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
- [ ] Send-back 2026-09-10 (Fable, `reviews/2026-09-10-advise.md`
      finding 1): holder is a **check** in the token
      (`check if holder($fp), $fp == "<fp>"`), never a `holder` fact
      in any block; the fact is verifier-injected only. Add the
      rejection scenario (token asserting a `holder` fact).
- [ ] Send-back 2026-09-10 (finding 2): release SHALL go only to the
      party that completed the holder proof, over a channel
      delegation-path intermediaries cannot read; application profile
      names the binding (overlay peer / holder-authenticated transport
      / sealed to a response key in the proof).
- [ ] Send-back 2026-09-10 (finding 3): one signed tuple in the
      requirement — token identity, nonce, audience (plus response key
      if a profile seals). Encoding stays `add-biscuit-runtime` /
      `ikp-6yz.2`.
- [ ] Send-back 2026-09-10 (rationale, not SHALL): Decision 1 and
      Rejected say the PAT "cannot be recrypted without GitHub". It
      can. Replace with the tier argument (PRE = durable read, no
      per-use policy, rotation re-keys holders; agency = redeemable
      use with TTL/scope/log, PAT rotates without re-issue).
- [ ] Fold notes from 2026-09-10 (not spec text): copy-out pointer to
      `add-secret-tokenator`; redemption profile is an online-verifier
      application (does not weaken capability-v1 §2); salt clause
      cites D-5 for low-entropy secrets.
- [ ] Cross-family re-advise after amend (ADR-005; not Grok).
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
