# Tasks

- [x] Vendor homoiconic `e9a4c86` `unikernel/quic.zig`, `entity.zig`, `entity-tool.zig` into `native/reflect_quic/` unmodified; NOTICE names the commit and the files.
- [x] Rewrite `native/reflect_quic/host.zig`: own key file, one expected guest name, `getrandom` per call, acknowledgement pumped before exit, exit 7 on a flight given up. Closes the gap in bead `mjolnir-6h01`.
- [x] `priv/reflect-quic-client` and `priv/reflect-entity` build commands in `native/reflect_quic/NOTICE` and `test/fixtures/reflect/README.md`. Both cross-compile for `x86_64-linux-musl` with Zig 0.16.
- [x] Spawn: `entity_key` (required, base58 of 32 bytes, not all zero) and `allow` (at most 7 names); named errors `entity_key_required`, `entity_key_invalid`, `allow_invalid`. `peer_pin` removed from HTTP, MCP, `mj`.
- [x] Mjolnir's client key: `:reflect_client_key` (default `<state_dir>/reflect-client.key`), created 0600 from `:crypto.strong_rand_bytes(32)`; names from `:reflect_entity` (default `priv/reflect-entity`), test override `:unikernel_entity_name`. Checked before a unikernel's process starts.
- [x] Boot: key file `<socket_dir>/<vm_id>.entity-key` (0600, never readable by another user), payload `initramfs`, four-word command line, readiness on `reflect: entity <name>` and `reflect: quic <port>`, `entity_name_mismatch`, prompt failure on a refused key file. File removed on ready, on every boot failure, on stop, and by the startup sweep.
- [x] Kept: `entity` and `allow` in `spawn_config` (running and guest-exit records), the API view and MCP. The key is held as a closure in memory and is in no record, log, event or response.
- [x] Exchange passes the client key file and the guest's name; exit 3 `peer_key_refused`, exit 7 `unikernel_timeout`.
- [x] `mj spawn --entity-key-file` / `--allow`, `mj entity name <key-file>`; the operator-socket spawn sends its body on curl's stdin, not argv.
- [x] Unit tests: `test/mjolnir/unikernel_test.exs`, `test/mjolnir/unikernel_lifecycle_test.exs`, `test/mjolnir/mcp/server_test.exs`, `mjolnir_client` `entity` and `spawn_body` tests.
- [x] Docs: `docs/architecture.md`, `test/fixtures/reflect/README.md`. Hardware runner `scripts/acceptance/unikernel.exs` updated.
- [x] Hardware acceptance on morphie with a `reflect-net.elf` built at homoiconic `e9a4c86`: `scripts/acceptance/unikernel.exs` passes; keep the transcript under `evidence/`.
- [x] Fold into `openspec/specs/unikernel-guest/spec.md` and archive.
