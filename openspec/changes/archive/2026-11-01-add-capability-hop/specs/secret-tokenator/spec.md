## ADDED Requirements

### Requirement: A recorded hop is nextKey attenuation

A holder-bound mint SHALL carry the holder check and zero hop blocks, and SHALL still authorize `redeem` for its secret when the verifier injects that holder. The host SHALL record a hop only by `append_hop` on the existing `mjolnir-biscuit` face. That operation SHALL append one block with `Biscuit::append` (nextKey) and SHALL NOT add a mint root, a Blake3, or a second Biscuit crate.

The block SHALL restate `check if holder($fp), $fp == "<fp>"` for the fingerprint already on the token and SHALL NOT add a `right` or any other operation. The host SHALL refuse `append_hop` when the token has no holder check, and SHALL NOT return a token in that case. An appended hop SHALL NOT make `redeem` succeed without the injected holder. Deposit SHALL NOT call `append_hop`. No hop SHALL be written to an identikey-log.

#### Scenario: Zero hop blocks still authorize

- GIVEN a holder-bound mint with no hop block
- WHEN the verifier injects that holder
- THEN `redeem` on that secret is authorized
- AND the token has no hop block

#### Scenario: A recorded hop keeps the holder check

- GIVEN that token
- WHEN the host appends one hop
- THEN authorization still requires the injected holder
- AND the new block adds no `right`

#### Scenario: A missing holder check cannot be hopped

- GIVEN a token that has no holder check
- WHEN `append_hop` is called
- THEN it returns an error
- AND no hop token is produced
