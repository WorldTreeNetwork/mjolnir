# update-redeem-tuple

> **ACTIVE BUILD**

## Why

A live redeem cannot be checked until the holder proof, the Tokenator nonce, and the proxy-use proof are one byte string. Capability v1 §7.1 left those bytes to this runtime. `add-tokenator-redeem` froze a four-line string that does not cover the request. api-proxy still signs a different frame, and matching that frame is a later change in that repo.

## What

- Replace `Mjolnir.Secrets.Redeem.signing_message/3` with one private length-prefix frame.
- Keep the Tokenator nonce: 64 lowercase hex, consumed before verify, burned on failure.
- Make egress call the signed method and resource. Stop reading an unsigned method and URL.
- Capability: `secret-tokenator`.

## Impact

- Capabilities: MODIFIED `secret-tokenator` (holder-proof requirement).
- ADRs: none.

## User journey & surfaces

No new UI because redeem and egress stay `POST /api/secrets/redeem` and `POST /api/egress`. A holder with a fresh nonce signs the new frame and receives the same success body. The old four-line string returns no secret.

## Out of scope

- Editing `canonical_bytes`, dialing Tokenator, and the dCBOR request map. Those stay in api-proxy.
- A second signature check in this handler. Two proofs still mean two signatures over this one string; this node checks the presented holder.
- Guest route, address pin, and relays (`mjolnir-86g6.2`).
- A new holder class in identikey-protocol.
