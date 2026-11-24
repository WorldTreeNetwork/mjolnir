# add-unikernel-entity-keys

> **ACTIVE BUILD** — Duke decided on 2026-11-24 that a guest has a key per entity; how Mjolnir does it here (the owner supplies the key at spawn, Mjolnir has one client key of its own) is the implementing agent's choice, made after homoiconic `add-entity-keys` (WorldTreeNetwork/homoiconic `e9a4c86`, bead `homoiconic-q59.49`). Bead `mjolnir-6h01`. No advise pass was run. Hardware acceptance passed on morphie on 2026-11-24 (`evidence/`). Folded 2026-11-24.

## Why

Until homoiconic `e9a4c86` every Reflect network image held one built-in P-256 key, and Mjolnir pinned its certificate by a SHA-256 `peer_pin` given at spawn. The pin named the image, not a guest: two guests from one image were one identity, and anyone with the source could present it.

From `e9a4c86` a guest has no built-in key. It runs for an *entity*, and the entity's key (32 bytes, an Ed25519 seed) is the one file given at boot (Cloud Hypervisor `--initramfs`). Without it the guest prints `reflect: no entity key` and powers off. The command line needs a fourth word, `reflect.allow=<name>[,<name>...]`: the entities the guest will finish a QUIC handshake with. The handshake is mutual: the client presents its own key, and accepts only a guest whose name it expects. A guest with a QUIC word no longer answers anything on plain `reflect.port`.

So images built at `e9a4c86` or later do not start under today's Mjolnir, and images built before it do not work with this change.

The vendored client (`native/reflect_quic/quic.zig`) is also an old copy (from `793b583`) that never acknowledges a guest's reply, so the guest resends every reply ten times (bead `mjolnir-6h01`).

## What

- **The owner's key.** Spawn of kind `unikernel` takes `entity_key`: the entity's 32-byte Ed25519 seed as base58. The caller supplies it and keeps it. Mjolnir never makes a key for a guest. Missing: `entity_key_required`. Not base58 of exactly 32 bytes, or all zero: `entity_key_invalid`.
- **Allowed callers.** Spawn takes `allow`: up to 7 entity names (base58, 32 bytes) that may also call the guest, for example through a published QUIC port. Otherwise `allow_invalid`.
- **Mjolnir's own key.** The host BEAM has one Ed25519 key as a QUIC client, a 0600 file (`:reflect_client_key`, default `<state_dir>/reflect-client.key`), made from 32 random bytes on first use. Names are computed by `priv/reflect-entity name <file>`, built from homoiconic's `entity-tool.zig`.
- **Boot.** The key is written to `<socket_dir>/<vm_id>.entity-key`, 0600, and given to Cloud Hypervisor as the payload `initramfs`. The command line is four words, the fourth `reflect.allow=<Mjolnir's name>[,<allow>...]`. Readiness is `reflect: quic <port>` and `reflect: entity <the name of the key>`; another name fails the boot with `entity_name_mismatch`. A guest that refuses its key file fails the boot at once. The file is removed on ready and on every failure and stop.
- **What is kept.** `spawn_config`, the API and MCP return the guest's name as `entity` and the `allow` list. The key is in no record, log, event or response. Old records holding `peer_pin` are read without error.
- **Exchange.** `native/reflect_quic/host.zig` takes `ip port budget key_file server_name program correlation`, presents Mjolnir's key, accepts only the guest's name, draws randomness from `getrandom` on every call, and pumps the acknowledgement of the reply before it exits. Exit 3 (the guest presented another name) is `peer_key_refused`; a new exit 7 (a flight given up with no answer: the guest does not allow this key, or is gone) is `unikernel_timeout`.
- **Clients.** `mj spawn --entity-key-file <path>` (exactly 32 bytes, sent as base58, never printed) and repeatable `--allow <name>`; `--peer-pin` is gone. `mj entity name <key-file>` prints a key file's name offline. MCP `spawn_vm` takes `entity_key` and `allow`.

Capability: `unikernel-guest`.

**Rigor:** architecture. **Blast:** protocol and custody (who holds an entity's key).

## Custody and the exit test

The key is the owner's. They make it with any tool (`head -c 32 /dev/urandom`) and keep it; its name can be computed offline by `mj entity name`, by `priv/reflect-entity`, or by identikey's own code. Mjolnir and its host hold the key while the guest runs: the launcher chose the guest's memory and can read it (homoiconic design §3, "the trust boundary"). Mjolnir keeps the key on disk only in a 0600 file for the duration of the boot, and never stores or returns it. Nothing makes the key recoverable only through Mjolnir: an owner who leaves keeps the key and the name and can run the entity elsewhere. Spawn without a key is refused rather than filled with a key Mjolnir made, so there is no Mjolnir-held key to hand back.

## Impact

- Capabilities: MODIFIED `unikernel-guest` (spawn, boot, exchange); ADDED requirements for key custody and Mjolnir's client key.
- Code: `lib/mjolnir/unikernel.ex`, `lib/mjolnir/unikernel/exchange.ex`, `lib/mjolnir/vm.ex`, `lib/mjolnir/cloud_hypervisor/config.ex`, `lib/mjolnir/cleanup.ex`, `lib/mjolnir/api/{router,views}.ex`, `lib/mjolnir/mcp/server.ex`, `native/reflect_quic/*`, `native/mjolnir_api/src/api.rs`, `native/mjolnir_client/src/{main,api,mcp,entity}.rs`.
- Breaking: an image built before homoiconic `e9a4c86` no longer boots under this Mjolnir (no `reflect: entity` line: `entity_name_mismatch`). A client sending `peer_pin` gets `entity_key_required`.
- Host: morphie (Linux x86_64, KVM, Cloud Hypervisor 54.0) for the hardware runner `scripts/acceptance/unikernel.exs`.
- Homoiconic tree: read only.

## User journey & surfaces

An entity owner makes a key file, runs `mj entity name key` to learn its name, and runs `mj spawn --kind unikernel --kernel <elf> --entity-key-file key [--allow <peer-name>]`. `mj` prints the VM id and `Entity: <name>`. `mj message <id> <program>` is unchanged. A peer named in `--allow` can call the guest directly over a published QUIC port with its own key. No new UI.
