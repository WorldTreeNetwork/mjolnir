# Tasks

- [x] Crate `native/mjolnir_biscuit` with `biscuit-auth` 6 and `blake3` 1
- [x] Binary BEAM face (no rustler `:blake3`, no HTTP)
- [x] Mint → serialize → `Biscuit::from` round-trip
- [x] Holder check fail-closed; matching injected `holder` fact allows
- [x] Tampered authority bytes fail parse
- [x] Blake3 empty vector
- [x] Holder fp = identikey-auth §5 dCBOR map (not raw pubkey Blake3)
- [x] Salted secret commitment; unsalted Blake3(secret) is not used
- [x] Elixir tests under `test/mjolnir/biscuit_test.exs`
