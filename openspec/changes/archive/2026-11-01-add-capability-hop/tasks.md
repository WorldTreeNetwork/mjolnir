# Tasks

- [x] `append_hop` appends one nextKey block that restates the holder check and adds no right
- [x] A token with no holder check is refused and no hop token is returned
- [x] Deposit still mints zero hop blocks
- [x] `mix test test/mjolnir/biscuit_test.exs` shows a holder-bound mint with zero hop blocks still authorizes, and a hop whose holder check is absent does not
- [x] On fold, the living purpose no longer lists hop as unbuilt

## Advise owed

- [x] Fresh advise after preparation

## Out of scope

- Deposit, redeem, the mint-root file, and third-party blocks
