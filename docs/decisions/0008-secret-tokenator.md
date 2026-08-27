# ADR 0008 — Secret tokenator (foreign secrets)

**Status:** Proposed
**Date:** 2026-08-26
**Change:** [`add-secret-tokenator`](../../openspec/changes/add-secret-tokenator/proposal.md)
**Living spec (after fold):** [`openspec/specs/secret-tokenator/spec.md`](../../openspec/specs/secret-tokenator/spec.md)
**Epic:** `mjolnir-axsb.1`
**Protocol:** [`update-identikey-capability`](../../openspec/changes/update-identikey-capability/design.md)
  → `identikey-capability-v1.md` after that change's act

Full argument:
[`openspec/changes/add-secret-tokenator/design.md`](../../openspec/changes/add-secret-tokenator/design.md).

## One screen

1. **PAT never travels.** Opaque SecretStore
   (`_opaque/secrets/<id>/value`). Biscuit names the id, not the
   bytes.
2. **Redeem on `api_url`.** `POST /api/secrets/redeem`. No new
   overlay port, no `tokenator_url`. SecretStore is Elixir; blob-door
   port split does not apply.
3. **Holder-plus-bearer.** Signature by the named public key over
   nonce + token identity. Stolen Biscuit bytes do not redeem.
4. **Tokenator sees redemptions.** Accepted and logged (id, holder,
   time, result). Never log `value`. Honest because the payload is a
   *foreign* secret. Recrypt PRE stays for our ciphertext (D-5).
5. **Reusable until TTL or key rotation.** Single-use is a later
   Datalog fact. v1 returns PAT bytes; a GitHub proxy is later.
6. **Code is later nodes.** This ADR is the architecture write.
   Runtime / redeem / mint / hop are `add-biscuit-runtime`,
   `add-tokenator-redeem`, `add-capability-mint`,
   `add-capability-hop`.

## Built vs remaining

Built: nothing of the HTTP path. SecretStore opaque already exists
(Buzz nsec).

Remaining: advise, then the four implement landings above. Guild
holder class and Papyrus UI are not this capability's first act.
