# Design

## The mounted handler is the route

`Mjolnir.API.Router` already posts `/api/secrets/challenge` and `/api/secrets/redeem` to `Mjolnir.Secrets.Redeem`. `Mjolnir.API.Auth` reaches those paths, and `/api/egress`, on the ceremony branch after sites tokens, the operator socket, and a presented Biscuit, and before JWT. The branch assigns `principal_kind: :ceremony` and an empty scope set. The handler proves the holder. That is the fourth-style branch from ADR 0008: not `@skip_auth_paths`, no VM-scope JWT, no second port, no `tokenator_url`.

The signed bytes are `mjolnir/redeem/v1\n<nonce>\n<biscuit-base64>\n<secret_id>`. Capability v1 §7 left that encoding to this runtime. This change freezes the encoding the handler already uses.

`Mjolnir.Secrets.Nonces` keeps the nonce in a GenServer for 60 seconds and deletes it on consume. A restart drops the table, so an outstanding challenge fails closed.

## Copy-out

The living requirement returns `{value, salt}` to the named holder. The handler returns `value_b64` and does not return the salt. Reconcile keeps the route and adds `salt_b64` on success. Error bodies stay free of secret bytes. The host does not write the secret onto a virtio-fs root. A guest that receives the copy keeps it in process memory or tmpfs. That guest write is not a second host store.

The salt is not generated at redeem. ADR 0008 stores it beside the value: opaque `value` and opaque `meta` for the same secret id. `meta` is UTF-8 JSON. Redeem reads `salt_b64` (exactly 32 bytes) and `commitment_hex` (32 bytes) and ignores other keys, including an owner fingerprint that mint may add later. Success requires `Mjolnir.Biscuit.secret_commit(salt, value)` to equal that commitment. Missing value, missing meta, malformed JSON, a bad length, or a mismatch returns no secret and no salt, and logs neither. A legacy value with no meta fails the same way. This change does not write the pair. Deposit stays `add-capability-mint`. Tests may `put_opaque` both keys as a fixture.

`prove/1` is shared with egress. Egress still returns upstream status and body only. A salt or commitment failure stops it before the upstream call.

The nonce is consumed before the signature and the Biscuit check. A wrong signer, a holderless token, the wrong resource or operation, or a tampered signed field burns that nonce. Retry takes a new challenge. The table is 60 seconds, memory only, and one GenServer, so one nonce has one winner. Restart drops it. Tests run with operator shortcuts and localhost bypass off, and a ceremony request does not open any other authenticated route.

## Unverified hypotheses

None.
