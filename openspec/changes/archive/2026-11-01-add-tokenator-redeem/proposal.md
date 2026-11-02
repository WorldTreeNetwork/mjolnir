# add-tokenator-redeem

> **ACTIVE BUILD**

Bead `mjolnir-reki.3`. **Rigor:** architecture. Group: human-gate. Activated by the campaign grant on `mjolnir-reki` ("activate and run").

## Why

ADR 0008 and the living `secret-tokenator` purpose still say the redeem route is unbuilt. The route is already mounted. `POST /api/secrets/challenge` and `POST /api/secrets/redeem` call `Mjolnir.Secrets.Redeem`. `Mjolnir.Secrets.Nonces` is supervised. The paths are not on `@skip_auth_paths`. The living spec should catch up to that handler, including the ceremony branch and the signed tuple, and the tests should round-trip a holder proof.

## What

- Keep `Mjolnir.Secrets.Redeem` as the handler. Do not mount a second route.
- Ceremony, before JWT, covers `/api/secrets/challenge`, `/api/secrets/redeem`, and `/api/egress`. It confers no scopes. The holder proof stays in the handler.
- The signed tuple is `mjolnir/redeem/v1`, nonce, biscuit base64, and secret id, one line each.
- Nonces are single-use and memory-only. Restart fails closed.
- Copy-out success returns the secret and the salt to that holder. It does not write a rootfs.
- On fold, the living purpose stops listing redeem as unbuilt. Mint and hop stay listed.

## Impact

- Capabilities: MODIFIED `Copy-out is v1; thin proxy is the more secure pattern`, `Redeem is on the existing API, narrow Auth branch`, and `Holder proof fail-closed, nonce single-use` on `secret-tokenator`
- ADRs: amend the "remaining" list in `docs/decisions/0008-secret-tokenator.md` when this folds

## User journey & surfaces

No new UI because the holder calls `POST {api_url}/api/secrets/redeem`. A fresh proof returns the secret and salt. A reused nonce returns no secret. No VM-scope JWT is required.

- **Working** — named holder, fresh nonce, holder check on the Biscuit, secret in the opaque vault.
- **Empty** — unknown secret id. No bytes.
- **Failed** — missing, wrong, expired, or reused nonce. No bytes.
- **Off** — operator socket and ordinary JWT routes are unchanged. Egress stays on the same ceremony branch and still does not return the secret in its body.

## Out of scope

- A new Blake3 or a new Biscuit crate.
- Deposit and owner-fingerprint meta (`add-capability-mint`).
- Hop blocks (`add-capability-hop`).
- The durable mint root's storage path (`add-biscuit-authority`).
- Dialing this route from api-proxy. `crates/proxy-tokenator` keeps refusing network URLs.
- A guild holder class.

## Preparation

Outcome: revised. Steer 2026-10-31: reconcile the tree and keep the ceremony branch, including egress. Code anchors: `lib/mjolnir/api/router.ex` posts, `lib/mjolnir/api/auth.ex` `ceremony?/1`, `lib/mjolnir/secrets/redeem.ex` `signing_message/3`, `lib/mjolnir/secrets/nonces.ex`. Today's success body is `value_b64` only. The 2026-10-31 advise send-back pins the salt: opaque `meta` beside `value`, 32-byte salt, commitment checked with `secret_commit/2`, legacy value-only fails closed, egress stays salt-free. A failed proof burns the nonce. Authority: campaign grant on `mjolnir-reki`, this dependency-ready node. Fresh advise is owed before act.
