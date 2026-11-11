# steer add-guild-compute-holder

Inherited from `add-aie-compute` / `mjolnir-io3b` (2026-11-07).

## Decided
- Grants: guild inject as `member(ks, pk)` in this DAG
- No new token crypto (identikey-capability D5)
- Holder is the consumer VM; member signs a delegation

## Feeds change
Lookup + delegation leaf + verifier inject. Mint without guild
still works.

## Advise 2026-11-11 (astra-arch-review)

Send-back. Pins: R1 current `mjolnir/aie-delegate/v1` leaf
(guild-wide); R2 roster adapter with authority map; R3
`Guild.admit/1` conjunction outside Biscuit Datalog.

## Advise 2026-11-11 pass 2 (astra-arch-review)

Send-back R4–R6. Pins: untrusted `member_pk` on the pending row;
Redeem-grammar signing bytes + SecretStore `aie_delegate` codec;
durable sequence floor vs generic delete.
