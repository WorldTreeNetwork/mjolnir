# Unikernel guest

## Current

`VM.do_boot/1` (`lib/mjolnir/vm.ex`) always clones a BTRFS rootfs, injects the guest agent, prepares virtiofsd, creates a TAP, and later waits for the agent on vsock. `spawn_body` (`native/mjolnir_client/src/api.rs`) does not send a guest kind or a kernel path. `POST /api/vms/:id/messages` delivers a mailbox payload through the agent. `mj` is an HTTPS client. The guest address is a host-local /32.

The Reflect image at homoiconic `793b583` is a static x86_64 ELF for one vCPU and 512 MiB. Its command-line parser (`unikernel/net.zig`) rejects any word it does not know. Readiness is the serial line `reflect: quic <port>`. Mjolnir already records serial in file mode (`lib/mjolnir/cloud_hypervisor/config.ex`).

QUIC v1 rides the guest UDP stack. One bidirectional stream carries one 24-byte `RFL1` header plus payload. The guest holds one connection. A second client's packets during an exchange are fed to that connection. The host pins SHA-256 of the compiled P-256 certificate before application data. A Lean budget exhaustion is still kind 1 status 0. Status 2 and 3 are transport errors with an empty payload. An oversize or malformed frame gets no reply and no FIN. `reflect.wire_port` is out of scope. This change does not add TCP.

A fatal request powers the guest off. Today a hypervisor exit plus restart policy `:always` makes Reconcile look for a rootfs and log `data lost — cannot resume`.

## Shape

`spawn_config.kind` is `linux` or `unikernel`. A missing kind, including records already on disk, stays `linux`.

For `unikernel`:

- Require `kernel` under `unikernel_kernel_prefixes`, and a 32-byte `peer_pin`. Reject anything else before a process starts. Reject `--memory` other than 512.
- Boot 1 vCPU and 512 MiB. Skip `clone_rootfs`, agent injection, virtiofsd, lan-files, and the vsock wait.
- Command line is exactly `reflect.ip=<guest> reflect.port=<udp> reflect.quic_port=<quic>`. No Linux `boot_args`.
- Readiness is the serial line `reflect: quic <port>`.
- Restart policy is `:never`. A self-exit sets `:stopped` / `guest_exit`. Reconcile does not resume and does not report a missing rootfs as data loss. Cleanup removes a leftover TAP and scope. Health skips the agent checks.
- The BEAM opens one QUIC connection on that guest's TAP. `mj` posts JSON and prints the decoded reply.
- One exchange at a time. A second caller gets `unikernel_busy` and no packet is sent.
- `exec`, `connect`, `snapshot`, `done`, `doctor`, `ticket`, and `url` return `unikernel_unsupported`.

Linux spawn, exec, message, and snapshot stay on the existing path.

## Message contract

Request JSON: `program_b64`, optional `budget` (default 100000000, range 1..100000000). Program after base64 decode at most 1176 bytes, rejected locally otherwise. Optional `id` is only the RFL1 correlation id.

The BEAM checks the pin, then writes one kind-0 RFL1 run. Response JSON: `transport_status` and `reply_b64` (payload only). Status 0 is HTTP 200, including a Lean budget payload. Status 2 is `reply_too_large`. Status 3 from the guest is `invalid_budget`. Deadline 60 seconds, then `unikernel_timeout`. The host does not parse Lean.

Fixtures for factorial and the 5000-step forever program are the stdout of that commit's `reply run`, stored in this repo with the commit id in the filename. Provenance is the homoiconic tree at `793b583`, not a re-encoding.

## Peer pin

The pin is SHA-256 of the certificate in the image. Every guest built from that commit shares it. The private key is in the homoiconic tree. The pin proves the host reached an image built with that certificate. It does not identify one guest.

`reflect.port` remains an unauthenticated UDP service because the image requires the word. Mjolnir does not send programs there. This change does not filter who can already route to the guest address. Closing that port is a homoiconic change.

## Where it runs

The QUIC spike and the KVM acceptance run on morphie (Cloud Hypervisor 54 at `~/ch54/cloud-hypervisor`, the ELF, KVM). The TAP in that spike is Mjolnir's /32 route and proxy ARP. `mix test` for the Linux path stays where it runs today. The Framework laptop is not the spike host.

## Out of scope

- A TCP listener on the guest.
- `reflect.wire_port`.
- Building `reflect.elf` here.
- Editing homoiconic.
- Filtering the plain UDP port.

## Unverified hypotheses

- **H1.** The host stack named below completes one handshake with the `793b583` listener over a Mjolnir /32 TAP. Confidence: low until that spike. The homoiconic `quic-client` is the same `quic.zig` on both ends, so it does not prove a different stack. Verification: one factorial exchange on morphie, spike only, no product code. If it fails, amend. Do not add TCP.

The spike holds these listener constraints fixed (`quic.zig` at `793b583`): QUIC version 1 only; destination and source connection ids of exactly 8 bytes; an X25519 key share found as the bytes `00 1d 00 20`; a ClientHello of at most 1024 bytes; `TLS_AES_128_GCM_SHA256`; ECDSA P-256 SHA-256; no ALPN required in the server reply; datagrams of at most 1400 bytes. The stack Mjolnir ships is a client written to those constraints, not a stock QUIC library on its default connection-id and ALPN settings.
