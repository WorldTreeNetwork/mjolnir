# Tasks

- [x] `mj compute share` / `mj compute run` (VM being principal)
- [x] Client `POST {aie_url}/v1/execute`: catalog `design_id` +
  bounded input; retry body carries `pending_id`
- [x] Mint holder-checked `mjolnir/aie-execute/v1` biscuit;
  `Offer.mint/2` incarnation on
  `right("<owner_fp>/<offer_id>/<incarnation>", "aie-execute")`
- [x] Guest retry of the same `pending_id` while the attempt is live
- [x] Third identity without a grant is 403
- [x] Close architecture scenarios: VM being is the offer principal;
  guest retry of live `pending_id`

## Out of scope

- Sidecar unit / admit / occupancy — folded `add-aie-host-sidecar`
- Offer leaf — folded `add-aie-keyspace-claims`
- Guild inject — folded `add-guild-compute-holder`
- OpenAI-compat chat API
- Fold of parent `add-aie-compute` before this landing

## Focused verification (2026-11-11)

`MIX_BUILD_PATH=/tmp/mjolnir-io3b6-build mix test test/mjolnir/aie/execute_test.exs --exclude integration --exclude postgres --exclude e2e`
completed **baseline-red**: 7/8 ExUnit tests passed; both Rust client
checks passed, including the BEAM/Rust proof-byte vector. The native
sidecar live-retry runtime test could not execute: unchanged
`native/mjolnir_aie_sidecar/src/occupancy.rs` requires the nix `user`
feature for `Uid` and passes `&File` to nix 0.29 `flock`, which requires
`RawFd` (lines 46, 76, 148). Those files/dependency settings are outside
this node's write set. The Elixir live-pending retry and principal
scenarios passed; native runtime verification remains subject to that
upstream build repair. The workspace lockfile was unchanged. No fold.
