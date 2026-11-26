# Vendored moq-webrtc

Base: `https://github.com/moq-dev/moq` `rs/moq-webrtc` at `4a6f522483168ace392718d68b58a402533c897d` (crate 0.3.12).

Outbound licence: `MIT OR Apache-2.0`, matching upstream. Authorised by Duke Jones for World Tree Network Foundation on 2026-11-25 ("license matches upstream") on bead `mjolnir-rurh.12`.

Tracking bead: `mjolnir-rurh.12`.

Drop condition: delete this directory, the harness `[patch]` line, and the `NOTICE` section when the moq pin contains this ingest behaviour (period, loss, eligible join) and the same ingest tests pass at that pin. Viewer-driven refresh is not part of the drop.

## Packaging differences

| Change | Why |
|---|---|
| `workspace = true` dependencies rewritten to the pin's versions, features, and `git` rev `4a6f52248` | The crate is no longer inside the moq workspace, and the other moq crates must stay the consumer's git copies |
| `workspace-hack` dev-dependency removed | It is a path into the moq tree |
| `[lints] workspace = true` removed | No workspace lints to inherit |
| `rust-version = "1.91"` set directly | It was `rust-version.workspace` |
| Empty `[workspace]` added | `cargo test` here does not climb into `native/` |
| `LICENSE-MIT` and `LICENSE-APACHE` copied from the moq root | The crate directory has none |
| `Cargo.lock` committed from the K1b resolution | Later builds use `--locked` |

`src/`, `CHANGELOG.md`, `MIGRATE.md`, and `clippy.toml` start byte-identical to the pin. The ingest patch is `patches/0001-edge-keyframes.patch` once P9 exports it.
