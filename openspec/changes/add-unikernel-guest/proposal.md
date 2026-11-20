# add-unikernel-guest

> **ACTIVE BUILD** — advise accepted 2026-11-19 (`fable-arch-review`).

## Why

Reflect (`WorldTreeNetwork/homoiconic` `793b583824a5de384bcb36cc4d111348d5a9f5f0`) boots on Cloud Hypervisor 54 with no Linux, no rootfs, and no guest agent. A program arrives as bytes. Lean returns the reply. Mjolnir's boot path always clones a rootfs, injects an agent, starts virtiofsd, and waits on vsock (`lib/mjolnir/vm.ex` `do_boot/1`). That path cannot start this guest.

The homoiconic bead still says readiness and messages are TCP. That text is stale. Duke chose UDP, then QUIC. The image already has QUIC v1 on `reflect.quic_port` (one RFL1 exchange, P-256 certificate) and a second port, `reflect.wire_port`, for one channel offer and one answer. This change uses that QUIC port and framing. It does not add a TCP server to the guest.

## What

- A guest kind `unikernel` at spawn, on HTTP, the `mj` CLI, MCP, and the persisted `spawn_config`.
- The unikernel boot path skips the rootfs clone, agent injection, virtiofsd, and the vsock wait. The kernel path and the command line carry the guest address.
- The host BEAM sends program bytes on one QUIC stream. `mj message` is the HTTPS client. The reply is the Lean payload, which Mjolnir does not decode. A wrong peer key is refused. A program that does not finish returns that payload with transport status 0, and the guest stays up.
- `mj kill` removes the tap and the scope. Restart does not resume.
- Linux spawns stay on the current path.

Capability: `unikernel-guest`.

**Rigor:** architecture. **Blast:** protocol (QUIC framing, peer key, no TCP).

## Impact

- Capabilities: ADDED `unikernel-guest`. Linux guest-lifetime requirements are not rewritten.
- Code, after an accepting advise: `lib/mjolnir/vm.ex`, Cloud Hypervisor config, API spawn and message, `native/mjolnir_client`, MCP spawn params.
- Host: morphie (Linux x86_64, KVM, Cloud Hypervisor 54.0). Not the Framework laptop.
- Homoiconic tree: read only. Bead `homoiconic-q59.17` stays open there.

## User journey & surfaces

No new UI because the surfaces are the existing spawn and message commands:

- `mj spawn --kind unikernel --kernel <reflect.elf> --peer-pin <sha256>`
- `mj message --budget <n> <id> <program-file>` prints the reply bytes
- `mj kill <id>` removes the tap and the scope

HTTP `POST /api/vms` and MCP spawn take the same kind and kernel. A wrong peer pin fails before application data. `examples/factorial` is the program.
