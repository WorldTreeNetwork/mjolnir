# Deposit and holder-checked mint

## Context

`Mjolnir.Secrets.Redeem.read_record/1` returns the secret only when opaque `value` and opaque `meta` agree. `meta` is UTF-8 JSON with `salt_b64` (exactly 32 bytes) and `commitment_hex` (64 lowercase hex). `Mjolnir.Biscuit.secret_commit/2` is that commitment. Redeem then authorizes `right(secret_id, "redeem")` only when a holder check is present and the verifier injects the fingerprint. No module writes that trio today. Tests build it by hand.

The durable root is `Mjolnir.Biscuit.mint_production/2`. `mint/3` stays the explicit-key helper.

## Decision

`Mjolnir.Secrets.Deposit.deposit/3` takes a path-safe `secret_id`, a non-empty secret binary, and a 32-byte Ed25519 owner public key.

It takes the id by exclusive create of the `secrets/<id>` directory (`mkdir` that fails with `eexist`). A directory that already exists, including a partial one or a leftover from a dead attempt, is preserved and not opened. Two racers cannot both win. Losing does not delete or replace the winner. `SecretStore.put_opaque/4` overwrites and shares a `<key>.tmp` path, so it is used only after this attempt owns the directory.

It draws 32 CSPRNG salt bytes, commits with `Biscuit.secret_commit/2`, and writes three opaque objects under that directory:

- `value` — the secret bytes
- `meta` — JSON object with only `salt_b64` and `commitment_hex`
- `owner` — lowercase hex of `Biscuit.holder_fingerprint/1` on the owner public key

`owner` is not inside the JSON. Redeem keeps ignoring unknown JSON keys, so this key does not change redeem.

The token is `mint_production(secret_id, "redeem")`, then `append_holder` with the published root public hex and that same fingerprint string. The authority block does not gain a holder fact. No hop block is appended. The token is returned only after `value`, `meta`, and `owner` are published and the holder check exists. There is no replace. An old token therefore cannot observe a new secret under the same id.

If mint, append, or a later write fails, this attempt deletes the directory it created, including `value.tmp`, `meta.tmp`, and `owner.tmp`. It does not return the token. If that delete fails, or the process dies after the create, the directory remains and the next deposit refuses it. The error and the logs do not contain the secret. A refusal before the create leaves every existing directory alone.

## Unverified hypotheses

None.

## Out of scope

Hop blocks, a deposit HTTP route, and any change to the redeem ceremony.
