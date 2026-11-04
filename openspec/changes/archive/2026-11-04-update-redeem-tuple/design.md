# update-redeem-tuple

## Preparation

Outcome: revised. The goal is unchanged. The four-line string named in the living requirement is the encoding steer replaced on 2026-11-04.

Anchors: `lib/mjolnir/secrets/redeem.ex` `signing_message/3` and `egress/1`; `Mjolnir.Secrets.Nonces`; `openspec/specs/secret-tokenator/spec.md` requirement "Holder proof fail-closed, nonce single-use". Authority: explicit activation of `mjolnir-86g6.1` only. Bounds: the steered field list, no dCBOR, no api-proxy edit, no dial, no guest-network work.

## Encoding

The signed bytes are a private length-prefix frame. They are not a dCBOR map and not the old newline string.

```
domain = "mjolnir/redeem/v1\0"
frame(field) = uint32 big-endian length || field bytes
message = domain
  || frame(biscuit base64)
  || frame(nonce)              # 64 lowercase hex
  || frame(audience)           # non-empty UTF-8, opaque label
  || frame(method)             # exact text, no case folding
  || frame(resource)
  || frame(body digest)        # 32 raw bytes, Blake3(decoded body)
  || frame(secret id)
  || frame(idempotency key)    # empty when the JSON field is missing or ""
```

The JSON object uses these string fields. A number, object, array, or null in any of them is a malformed proof. `public_key` and `signature` are base64 and are not framed. A client-supplied digest field is ignored. The verifier computes the digest.

| JSON key | Frame field | Missing | Empty string |
|---|---|---|---|
| `biscuit` | exact UTF-8, then base64-decode for the token | reject | reject |
| `nonce` | exact 64 lowercase hex | reject, do not consume | reject, do not consume |
| `audience` | exact UTF-8 | reject | reject |
| `method` | exact UTF-8 | reject | reject |
| `resource` | exact UTF-8 | reject | reject |
| `secret_id` | exact UTF-8 | reject | reject |
| `body_b64` | not framed; Blake3 of the decoded bytes is framed | digest of `<<>>` | digest of `<<>>` |
| `idempotency_key` | exact UTF-8 | empty field | empty field |

`body_b64` is standard base64 of the upstream body. The digest covers those decoded bytes, not the outer JSON and not a reserialized object. Egress forwards those same decoded bytes. Malformed base64 rejects. There is no separate body-digest parameter.

Audience is an opaque signed label. This verifier does not compare it to a host name, a configured identity, or the resource.

Method text is exact. `get` is not `GET`. Copy-out accepts only the four characters `REDEEM` and a resource equal to `secret_id`. Egress accepts only `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, and `HEAD`, and uses `resource` as the URL. Keys `url` and any other method alias are not read. Their presence does not reject and does not change the call.

A nonempty `idempotency_key` is sent as the header `Idempotency-Key` with that exact value. This node does not deduplicate on it. An empty key adds no header.

`prove/1` consumes a well-formed nonce before the remaining checks. Any failure after that burns it. It then verifies one Ed25519 signature over `message` by the presented 32-byte public key, injects `holder(<fingerprint>)`, and evaluates the biscuit as it does now.

`allow_url/1` still refuses a host outside the configured list after the signature checks. A rejected egress proof makes no upstream call.

A proof over the old four-line string fails. Generation, epoch, API id, operation id, and parameters are not in this frame. The later api-proxy signer has to emit this frame.

### Golden frame

Body bytes are the two bytes `hi`. Blake3 of that body is `85052e9aab1b67b6622d94a08441b09fd5b7aca61ee360416d70de5da67d86ca`. Blake3 of an empty body is `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`.

```json
{
  "biscuit": "dG9r",
  "nonce": "abababababababababababababababababababababababababababababababab",
  "audience": "proxy",
  "method": "POST",
  "resource": "https://127.0.0.1/v1",
  "body_b64": "aGk=",
  "secret_id": "github-pat",
  "idempotency_key": "k1"
}
```

The frame, hex, is `6d6a6f6c6e69722f72656465656d2f763100000000046447397200000040616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261620000000570726f787900000004504f53540000001468747470733a2f2f3132372e302e302e312f76310000002085052e9aab1b67b6622d94a08441b09fd5b7aca61ee360416d70de5da67d86ca0000000a6769746875622d706174000000026b31`. A test constructs this hex without calling `signing_message/3`.

## Unverified hypotheses

None. The field list was chosen in steer. No spike is open on this node.
