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

1. **Vault is a Gordian envelope.** Owner-signed; secret assertion
   present at rest, **elided** in flight. Copy-out is checked
   against that digest. Envelope SecretStore keyed by owner, not
   raw `put_opaque`.
2. **Redeem on `api_url`.** `POST /api/secrets/redeem`. No new
   overlay port. Auth plug: fourth branch (redeem-only), not
   `@skip_auth_paths`.
3. **Holder-plus-bearer.** Signature by the named key; Datalog
   `holder(<fingerprint>)`. Stolen Biscuit bytes do not redeem.
   Challenge nonce is single-use.
4. **Copy-out is v1 (superset).** Thin proxy VM/agent is the more
   secure pattern (holder redeems and calls upstream; fat agents
   never copy-out). Do not write copy-out onto virtio-fs.
5. **Tokenator sees redemptions.** Accepted and logged (id, holder,
   time, result). Never log secret bytes. Foreign secrets only.
   Recrypt PRE stays for our ciphertext (D-5).
6. **Code is later nodes.** Runtime / redeem / mint / hop are
   `add-biscuit-runtime`, `add-tokenator-redeem`,
   `add-capability-mint`, `add-capability-hop`.

## Built vs remaining

Built: nothing of the HTTP path. Envelope SecretStore exists
(signature verify stubbed). Opaque remains for Buzz nsec only.

Remaining: advise, then the four implement landings above. Guild
holder class and Papyrus UI are not this capability's first act.
