# adopt-reflect-space-and-retry

> **ACTIVE BUILD** — activated 2026-11-25 by the homoiconic orchestrator at Duke's request ("bring Mjolnir's unikernel guest up to date with the current Reflect image, and prove it again on morphie"), covering beads `mjolnir-qwo5`, `mjolnir-1tvc` and `mjolnir-0wm4`. Rigor `change`: no new dependency, no new protocol of Mjolnir's own (the QUIC code is homoiconic's, copied unmodified), and no change to who holds a key. No advise pass is owed at this rigor.

## Why

Homoiconic `main` (`3122521`) changed the Reflect network image in three ways that reach Mjolnir:

- **QUIC admission** (`695ce77`, homoiconic `add-quic-admission`). A guest holds 12 connections: 4 first-flight slots for clients that have shown nothing, 8 for clients that answered a Retry. When the first-flight slots are full it answers a new Initial with a Retry (RFC 9000 §17.2.5). Mjolnir's vendored `native/reflect_quic/quic.zig` is homoiconic's `e9a4c86` copy and ignores a Retry, so while another host keeps the four first-flight slots full Mjolnir's own messages wait for a free slot or are not served at all (`mjolnir-qwo5`).
- **A space limit** (`7efea06`, homoiconic `add-space-budget`). Each run may make at most a given number of cells. A run that passes the limit, or whose answer would be too large to write out, is answered `81 07` (CBOR `[7]`) with transport status 0; the guest keeps serving. Before, the same run ended the guest in `INTERNAL PANIC: out of memory`. The guest's owner sets the limit with `reflect.space=<cells>` at boot; the default, 4000000, is chosen for a 512 MiB guest. Mjolnir neither names that reply nor can set the limit (`mjolnir-1tvc`).
- **Cheaper runs.** Steps are charged by the work they do, a tail call pushes no frame, and deep nesting no longer fills the stack. The two fixture replies are byte-identical. But `forever` at 100000000 steps is now the budget reply, not a guest crash, so the runner's self-exit check needs another way to make a guest power itself off.

Separately, nothing in deploy builds `priv/reflect-quic-client` or `priv/reflect-entity`, so a unikernel spawn fails its preflight on any host where nobody built them by hand (`mjolnir-0wm4`).

## What

- **Retry.** Copy homoiconic `unikernel/quic.zig` from `3122521` into `native/reflect_quic/` unmodified (`entity.zig` and `entity-tool.zig` are unchanged since `e9a4c86`). `host.zig` needs no change: `Conn.recv` takes the Retry, and the public fields and calls it uses are unchanged. NOTICE names the new commit.
- **Space at spawn.** Spawn of kind `unikernel` takes `space`, the guest's cell limit: an integer from 1 to `:unikernel_space_max` (host config, default 4000000), default 4000000. Otherwise `invalid_space` before a process starts. The command line gains a fifth word, `reflect.space=<space>`, always written, so the limit a guest runs under is the one recorded and not the image's built-in default. It is persisted in `spawn_config` and returned by the API and MCP. It reaches spawn by HTTP, `mj spawn --space <cells>`, and both MCP `spawn_vm` implementations.
- **Reply outcome.** The message response gains `outcome`, the name of the reply envelope's tag (homoiconic `wire-bytes`, "A bounded run reply has a byte form"): `value` `[0, v]`, `budget` `[1]`, `refused` `[2]`, `unbound` `[3, i]`, `wrong` `[4]`, `fault` `[5]`, `unrepresentable` `[6]`, `space` `[7]`, and `unknown` for bytes that are none of these. Only the first two bytes are read; the value is not decoded. HTTP and the Elixir MCP set it, and the Rust MCP passes it through. `mj message` still prints the reply bytes, and nothing else, on stdout, and for every outcome but `value` prints `mj: outcome <name>` on stderr. Its exit status stays 0.
- **Deploy.** `scripts/build-release.sh` builds both Zig helpers into `priv/` with Zig 0.16.0 before `mix release`, so every release, `--app-only` included, carries them. `scripts/build-reflect-quic.sh` is the one build command; NOTICE, the fixtures README and the Justfile (`just build-reflect`) point at it. `priv/reflect-quic-client` and `priv/reflect-entity` are ignored by Git.
- **Key file on detach.** A hot-cutover detach of a unikernel in the middle of its boot removes `<socket_dir>/<vm_id>.entity-key` (today only the next startup sweep does).
- **The key in a crash report.** Bandit logs a crashed request with `Exception.format/3`, which prints the arguments of the top stack frame for a `FunctionClauseError`, and a `conn` there carries `body_params`. So the router takes `entity_key` out of `body_params` and `params` immediately after parsing and holds it in `conn.private` as a closure (`Mjolnir.Unikernel.entity_key_fun/1`), the same way spawn options hold it.
- **Acceptance.** The morphie runner is rerun against an image built fresh from homoiconic `origin/main`, with new checks: a program that passes its space answers `81 07`, outcome `space`, and the guest then answers factorial; a message is served within a second while a second address floods the guest's first-flight pool (Mjolnir's client must answer a Retry), with the `e9a4c86` client as a control; a message is served within a second while four stalled handshakes hold the first-flight pool; the command line carries `reflect.space`; a guest spawned with an operator-raised space limit and given `deep` panics and is recorded `stopped / guest_exit`. `mix test` runs on morphie (Linux) as well as the Mac.

Capability: `unikernel-guest`.

## Impact

- Capabilities: MODIFIED `unikernel-guest` (boot command line and spawn, message response); ADDED `unikernel-guest` requirements for the deployed helpers and the key in a crash report.
- ADRs: none. `docs/architecture.md` is unchanged: the shape (host BEAM opens QUIC, one exchange, reply bytes not decoded) stays.

## Exit test

Unchanged. The entity key is still supplied and kept by its owner and never stored. The space limit is a property of a guest the owner starts; it is recorded beside the guest's name and can be given to any other host that runs the same image.

## User journey & surfaces

An operator or agent spawns a unikernel with `mj spawn --kind unikernel --kernel <elf> --entity-key-file <key> [--space <cells>]` or MCP `spawn_vm`; `mj info` and `--json` show the space. `mj message --budget <n> <id> <program>` prints the reply bytes; when the run did not end in a value, stderr says which outcome (`mj: outcome space`). `--json` and MCP `deliver_message` carry `outcome`. Failed: `invalid_space` at spawn. Off: Linux spawns are unchanged.

## Out of scope

- The crossing (`reflect.wire_port`, `reflect.peer`, form 2 records with per-guest budgets): Mjolnir does not start crossing guests.
- `reflect.space` for guests with memory other than 512 MiB: unikernel memory stays fixed at 512 MiB.
- The MCP transport (`ex_mcp`) printing a request's arguments, which hold `entity_key`, if it crashes. Filed as a bead if it is found to.
