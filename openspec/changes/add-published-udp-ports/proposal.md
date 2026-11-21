# add-published-udp-ports

> **ACTIVE BUILD** — activated in chat 2026-11-20. Bead `mjolnir-ol8n`. No advise pass was run.

## Why

A guest has a private /32 behind the host's MASQUERADE. Nothing reaches it from outside except Iroh and the HTTP gateway. A QUIC service in a guest (a Media-over-QUIC relay, the Reflect unikernel's QUIC listener) needs a UDP port that the internet can address. QUIC carries every connection on one UDP port, so one published port per service is enough.

The LAN share (`lan-files`) already DNATs one TCP port to one configured VM. That is host config for one guest. This change is the general form: any VM, UDP, chosen at spawn.

## What

- Spawn takes `published_ports`, a list of `{host_port, guest_port}` for UDP. It is stored in `spawn_config`.
- Once the TAP exists the host writes one nat `PREROUTING` DNAT and two conntrack-scoped `FORWARD` accepts per port. No userspace proxy.
- The rules go when the VM stops. Cleanup removes rules of VMs that have no `:running` record.
- The host operator opts in with `published_port_range`. The default is off. Reserved ports, ports the host has bound, and ports another VM holds are refused before a process starts.
- `mj spawn --publish-udp HOST[:GUEST]`, MCP `spawn_vm`, and `mj info` carry it.
- Both guest kinds. For a unikernel, `guest_port` may be `quic`.

Capability: `published-ports`.

**Rigor:** change. **Blast:** host firewall (nat and filter rules tagged per VM), spawn API (one optional field).

## Impact

- Capabilities: ADDED `published-ports`. `lan-files` is not changed.
- Code: `lib/mjolnir/published_ports.ex` (new), `network.ex` (pure rule builder), `vm.ex`, `cleanup.ex`, `reconcile.ex`, `api/router.ex`, `api/views.ex`, config, `native/mjolnir_api`, `native/mjolnir_client`.
- Host: no deploy step. A host that does not set `MJOLNIR_PUBLISHED_PORT_RANGE` behaves as before.
- Records on disk without the field resume with no published ports.

## User journey & surfaces

No new UI because the surfaces are the existing spawn and info commands:

- `mj spawn --publish-udp 20001:4433`
- `mj info <id>` prints `udp <host address>:20001 -> <guest ip>:4433`
- `mj kill <id>` removes the rules

## Out of scope

- TCP. The field carries `protocol` so it can be added.
- IPv6.
- Hairpin: a guest or the host itself reaching the published address. The rule matches the public interface only.
- Changing the ports of a VM that is already running.
- Per-account quotas beyond the per-VM cap.
- Opening the port in a cloud firewall or `ufw`'s INPUT policy. The accepts are in `FORWARD`, where this traffic goes.
