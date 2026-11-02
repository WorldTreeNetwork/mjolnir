# ADR 0008 — Secret tokenator (foreign secrets)

**Status:** Accepted (Fable 5.1, 2026-09-10)
**Date:** 2026-08-26
**Change:** [`add-secret-tokenator`](../../openspec/changes/archive/2026-09-10-add-secret-tokenator/proposal.md) (folded 2026-09-10)
**Living spec:** [`openspec/specs/secret-tokenator/spec.md`](../../openspec/specs/secret-tokenator/spec.md)
**Epic:** `mjolnir-axsb.1` (tokenator slice closed by `mjolnir-reki`, 2026-11-01)
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
6. **Host code has landed.** Runtime is `add-biscuit-runtime`
   (folded 2026-09-26, bead `mjolnir-axsb.1.3`) plus the durable
   mint root `add-biscuit-authority` (folded 2026-11-01,
   `mjolnir-reki.1`). Redeem, deposit, and hop folded 2026-11-01
   from `add-tokenator-redeem` (`mjolnir-reki.3`),
   `add-capability-mint` (`mjolnir-reki.2`), and
   `add-capability-hop` (`mjolnir-reki.4`). A recorded hop is one
   nextKey block that restates the holder check and adds no
   right. It is not an Identikey-signed third-party block.

## Built vs remaining

Built: opaque vault + salted Blake3 commitment
(`Blake3("mjolnir/secret-commit/v1" || salt || secret)` on the
`mjolnir-biscuit` face; `Sites.Crypto.blake3_hash/1` stays a
SHA-256 stub and is not this commitment); path-safe id; guests do
not write; copy-out is v1 and thin proxy is the more secure
pattern; redeem on existing `api_url` in the BEAM, ceremony branch
before JWT, not `@skip_auth_paths`, no VM-scope JWT; holder-bound
redeem; single-use nonce; secret bytes not in logs; Recrypt PRE is
not this vault. Deposit is `Mjolnir.Secrets.Deposit.deposit/3`:
exclusive create, opaque `value`, JSON `meta` (`salt_b64`,
`commitment_hex`), opaque `owner` fingerprint, holder-checked
token only after those three objects exist. No HTTP deposit route.
Authority is the mode-0600 file loaded before redeem is served.
The daily sites backup excludes `keyspace/_opaque/**`
(`mjolnir-jhpu`). Copies already on B2 stay until they are deleted
there.

Remaining, and not this capability's host slice: guild holder
class, Papyrus mint UI, and VM-exec dual-mode Biscuit
(`docs/plans/rbac-design.md` Phase 1, `mjolnir-k8y.5`).
Identikey-signed third-party hops are not v1. The client wallet
store `identikey-secret` is a different commitment domain and is
not this vault.
