# Tasks

Architecture artifacts for `update-identikey-capability`. Copying
into the protocol spec is `act` after advise accept. Grok authored;
advise reader must not be Grok (ADR-005). Fable 5 is the
cross-family reader. Sol is not subscribed.

- [x] Write `design.md` (decisions)
- [x] Delta `specs/identikey-capability/spec.md` (ADDED)
- [ ] Advise accept (Fable) — `reviews/<date>-advise.md`
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
