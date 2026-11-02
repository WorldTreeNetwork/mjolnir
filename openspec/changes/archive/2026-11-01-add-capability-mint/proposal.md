# add-capability-mint

> **ACTIVE BUILD**

Bead `mjolnir-reki.2`. **Rigor:** architecture. Group: human-gate. Activated by the campaign grant on `mjolnir-reki` ("activate and run") after `add-biscuit-authority` landed.

## Why

Redeem already reads a deposited secret. It does not write one. A foreign secret still has no host deposit that stores the opaque value, the salted commitment redeem checks, and the owner fingerprint, then mints a Biscuit with a holder check and no secret bytes.

## What

- `Mjolnir.Secrets.Deposit` writes the vault and mints with the durable production root.
- The secret bytes live only at `SecretStore` opaque `secrets/<id>/value`.
- Opaque `meta` is the UTF-8 JSON redeem already parses: `salt_b64` (32 bytes) and `commitment_hex` (64 lowercase hex of `Mjolnir.Biscuit.secret_commit/2`).
- The owner fingerprint is a separate opaque key, `owner`, not a field inside that JSON and not a Gordian envelope.
- The token is `right(<secret_id>, "redeem")` plus a holder check. It does not assert a holder fact and it does not carry a hop block.
- On fold, the living purpose stops listing mint as unbuilt. Redeem and hop stay listed.

## Impact

- Capabilities: ADDED `Deposit mints a holder-checked token` on `secret-tokenator`
- ADRs: none

## User journey & surfaces

No new UI because deposit is the host function `Mjolnir.Secrets.Deposit`. The holder still proves itself on the existing redeem route. This change adds no HTTP route.

- **Working** — a path-safe id, a non-empty secret, and a 32-byte owner public key. The owner fingerprint reads back from the `owner` object. The minted token authorizes only when the verifier injects that fingerprint.
- **Empty** — an empty secret is refused. No vault object is left behind.
- **Failed** — a bad id, a bad owner key, or a missing mint root. No partial vault object.
- **Off** — redeem, egress, hop, and the guest fence are unchanged.

## Out of scope

- A second redeem route, a second Blake3, or a new Biscuit crate (`add-biscuit-runtime`, folded).
- Where the mint root file lives (`add-biscuit-authority`, folded, commit `b640e81`).
- Hop blocks (`add-capability-hop`).
- Folding the redeem change (`add-tokenator-redeem`). Its open fold box stays there.
- An HTTP deposit route, an api-proxy dial, and `POST /v1/execute`.
- A guild holder class.

## Preparation

Outcome: revised. Authority `mjolnir-reki.1` is closed. Commit `b640e81` loads `Mjolnir.Biscuit.authority/0` and `mint_production/2`. Redeem commit `9207fa9` reads `value` and JSON `meta` (`salt_b64`, `commitment_hex`) in `lib/mjolnir/secrets/redeem.ex` and ignores extra JSON keys. Its design says the owner fingerprint is mint's job. The bead's "another opaque key" is `owner`; the acceptance phrase "from meta" means that metadata beside `value`, not a new key inside the JSON redeem owns. Holder check is `Mjolnir.Biscuit.append_holder/3` and `authorize/6`. Fingerprints stay `Biscuit.holder_fingerprint/1` (auth-challenge v1 §5). The 2026-11-01 send-back is applied: the id is exclusive-create, an existing or partial directory is preserved, and success is the holder-checked token only after the three objects are published. Cleanup failure and process death leave that directory reserved. Authority for this node is the campaign grant on `mjolnir-reki`. Fresh advise of this revised contract is owed before act.
