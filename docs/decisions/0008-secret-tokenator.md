# ADR 0008 — Secret tokenator (foreign secrets)

**Status:** Accepted (Fable 5.1, 2026-09-10)
**Date:** 2026-08-26
**Change:** [`add-secret-tokenator`](../../openspec/changes/archive/2026-09-10-add-secret-tokenator/proposal.md) (folded 2026-09-10)
**Living spec:** [`openspec/specs/secret-tokenator/spec.md`](../../openspec/specs/secret-tokenator/spec.md)
**Epic:** `mjolnir-axsb.1`
**Protocol:** identikey-protocol
  [`identikey-capability-v1.md` §7](https://github.com/identikey/identikey-protocol/blob/main/docs/standards/identikey-capability-v1.md#7-secret-redemption-profile-foreign-secrets)
  (secret-redemption profile; folded from
  [`update-identikey-capability`](../../openspec/changes/archive/2026-09-10-update-identikey-capability/design.md)
  2026-09-10)

Full argument:
[`openspec/changes/archive/2026-09-10-add-secret-tokenator/design.md`](../../openspec/changes/archive/2026-09-10-add-secret-tokenator/design.md).

## One screen

1. **Opaque vault + salted Blake3 commitment.** `put_opaque`
   `_opaque/secrets/<id>/value` + `meta` (salt, commitment).
   Commitment is `Blake3(domain || salt || secret)`. Salt travels;
   secret does not. Unsalted hashes of the secret are forbidden.
   Gordian envelopes deferred; when they return, elision is salted.
2. **Redeem on `api_url` (in the BEAM).** `POST /api/secrets/redeem`.
   No new overlay port. Auth plug: fourth branch (redeem-only), not
   `@skip_auth_paths`. Sidecar variants compared 2026-08-26; **A
   is v1.** Revisit if redeem is no longer “once per job.”
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

Built (living spec, fold-now): opaque vault + salted Blake3
commitment shape (`put_opaque("secrets", …)`; path-safe id; guests
do not write; unsalted hash and SHA-256 stub are review-reject);
copy-out is v1, thin proxy is the more secure pattern, proxy-only
v1 is review-reject; redeem on existing `api_url` in the BEAM, no
new overlay port, not `@skip_auth_paths`, no VM-scope JWT;
holder-bound redeem (signature + `holder(<fp>)`; reused nonce
fails closed); secret bytes not in logs; Recrypt PRE is not this
vault. Opaque `put_opaque` exists (Buzz nsec). Real Blake3 NIF is
not wired (`Sites.Crypto.blake3_hash/1` is SHA-256).

Remaining (do not import as living SHALLs): `add-biscuit-runtime`
(real Blake3 NIF / authority key), `add-tokenator-redeem`
(challenge + POST handler; fourth Auth branch; nonce store;
copy-out bytes), `add-capability-mint` (deposit + mint; `meta`
owner fingerprint), `add-capability-hop` (signed block per hop).
Guild holder class and Papyrus UI are not this capability's first
act.
