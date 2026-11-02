# add-capability-hop

> **ACTIVE BUILD**

Bead `mjolnir-reki.4`. **Rigor:** architecture. Group: human-gate. Activated by the campaign grant on `mjolnir-reki` ("activate and run") after `add-capability-mint` landed.

## Why

A deposit now mints a holder-checked redeem token and stops. A recorded hop has nowhere to go. v1 records one only by appending a nextKey attenuation block. The holder check has to stay, and the block must not widen redeem.

## What

- `append_hop` on the existing `mjolnir-biscuit` face appends one nextKey block. Deposit does not call it. A holder-bound mint still has zero hop blocks.
- The block restates that same holder check. It adds no operation and no broader right.
- The wrapper uses `Biscuit::append` on the type `identikey-capability` 0.1.0 already re-exports. It does not add a second mint root or a second Blake3.
- A token with no holder check cannot gain a hop. Redeem of a holder-bound token with zero hops stays valid.
- On fold, the living purpose stops listing hop as unbuilt. Mint and redeem stay listed until their own folds.

## Impact

- Capabilities: ADDED `A recorded hop is nextKey attenuation` on `secret-tokenator`
- ADRs: none

## User journey & surfaces

No new UI because a hop is another block on the token the holder already redeems. The tests are `mix test test/mjolnir/biscuit_test.exs`.

- **Working** — a holder-bound mint with zero hop blocks still authorizes redeem when the holder is injected. After one nextKey block, that is still true.
- **Empty** — no hop was recorded. The token is the deposit token.
- **Failed** — the source token has no holder check, or the block would add an operation. No hop token is returned.
- **Off** — deposit, redeem, and the guest fence are unchanged.

## Out of scope

- Identikey-signed third-party blocks and `identikey-log`.
- A second Biscuit crate or a second Blake3.
- Editing deposit, redeem, or the mint-root file.
- A guild holder class, an api-proxy dial, and `POST /v1/execute`.

## Preparation

Outcome: still valid. Mint `mjolnir-reki.2` is closed at `00fe8f2`. `Mjolnir.Secrets.Deposit` appends a holder check and no hop block. `identikey-capability` 0.1.0 exports `mint_right`, `parse`, `append_holder_check`, and `authorize`. `append_holder_check` is `Biscuit::append` of one check. No `nextKey` wrapper is in that crate or in `native/mjolnir_biscuit`. The bead's landing is that wrapper on this face, not a new crate. Authority for this node is the campaign grant on `mjolnir-reki`. Fresh advise is owed before act.
