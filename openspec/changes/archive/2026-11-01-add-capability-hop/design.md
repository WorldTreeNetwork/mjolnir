# Recorded hop

## Context

`identikey-capability` 0.1.0 re-exports `biscuit_auth::Biscuit`. `append_holder_check` already calls `Biscuit::append`, which signs the new block with the token's current nextKey. Deposit uses that for the holder check and then stops. The crate has no hop helper.

The archived capability decision says a recorded v1 hop is nextKey attenuation, not an Identikey signature. Third-party blocks are not this node.

## Decision

`mjolnir-biscuit` gains one op, `append_hop`. It parses with the existing root public key, refuses a token that does not already carry the holder check, and appends one block. The block's only check is the same `check if holder($fp), $fp == "<fp>"` already used by `append_holder_check`, bound to the fingerprint already on the token. It does not add a `right`. `Biscuit::append` cannot delete earlier checks, so the holder check remains.

Deposit does not call this op. A process death while appending leaves the caller with the previous token; the function returns the new bytes only after `to_vec` succeeds.

## Unverified hypotheses

None.

## Out of scope

Third-party Identikey blocks, `identikey-log`, and any change to redeem's ceremony.
