# unikernel-guest

## ADDED Requirements

### Requirement: Spawn selects a guest kind

The system SHALL accept guest kind `linux` or `unikernel` on HTTP spawn, `mj spawn`, and MCP spawn, and SHALL persist that kind in `spawn_config`. An omitted kind, including a persisted `spawn_config` that has no kind, SHALL be `linux`. Kind `unikernel` SHALL require a kernel path under the configured `unikernel_kernel_prefixes` allow-list, a peer pin, and SHALL NOT require a base image or a snapshot. A kernel path outside that allow-list SHALL be rejected before a process starts. Kind `linux` SHALL keep the current rootfs, agent, virtiofs, and vsock boot.

The peer pin SHALL be the SHA-256 of the P-256 certificate compiled into that image. It names the image's certificate. It does not name one guest, and it is not a secret from anyone who has the image source.

#### Scenario: Linux spawn is unchanged

- GIVEN a spawn request with no kind
- WHEN the guest boots
- THEN the boot path clones a rootfs, injects the agent, starts virtiofsd, and waits for vsock as it does today

#### Scenario: Unikernel spawn records the kernel and the pin

- GIVEN kind `unikernel`, a kernel path inside the allow-list, and a 32-byte peer pin
- WHEN spawn is accepted
- THEN `spawn_config` stores kind `unikernel`, that kernel path, and that pin

#### Scenario: Kernel path outside the allow-list

- GIVEN kind `unikernel` and a kernel path outside `unikernel_kernel_prefixes`
- WHEN spawn is requested
- THEN the response is the named error `kernel_not_allowed` and no hypervisor process starts

### Requirement: Unikernel boot has no rootfs and no agent

For kind `unikernel` the boot path SHALL skip the rootfs clone, guest-agent injection, virtiofsd, and the vsock wait. It SHALL start the given ELF as the Cloud Hypervisor kernel with exactly 1 vCPU and 512 MiB. A `--memory` value other than 512 SHALL be rejected before boot. The kernel command line SHALL be exactly these three words and no others: `reflect.ip=<guest> reflect.port=<udp> reflect.quic_port=<quic>`, using the address allocated for that TAP. Readiness SHALL be the serial line `reflect: quic <quic>` in the existing file-mode serial log. The system SHALL NOT open a TCP server on the guest and SHALL NOT send a program on `reflect.port`.

`reflect.port` stays open because the image requires the word. Mjolnir does not send programs there. Any process that can already route to that guest address can use that unauthenticated UDP service. This change does not add a filter. The QUIC pin does not cover that port.

#### Scenario: Boot reaches the QUIC port

- GIVEN a Reflect ELF from homoiconic `793b583` and a kernel path inside the allow-list
- WHEN the unikernel guest becomes ready
- THEN no rootfs subvolume and no virtiofsd process exist for that guest, the command line is only the three `reflect.*` words, the machine has 1 vCPU and 512 MiB, and the serial log contains `reflect: quic` followed by the configured port

#### Scenario: Memory other than 512

- GIVEN kind `unikernel` and `--memory` set to a value other than 512
- WHEN spawn is requested
- THEN the response is the named error `unikernel_memory` and no hypervisor process starts

### Requirement: The host opens one QUIC exchange per message

The Mjolnir BEAM on the guest's host SHALL open the QUIC v1 socket on that guest's TAP. `mj` SHALL only call the HTTPS API. It SHALL NOT open a socket to the guest address.

`POST /api/vms/:id/messages` for this kind SHALL read a JSON body `{"program_b64": "<standard base64>", "budget": <integer>}` and SHALL ignore a mailbox `payload`. `budget` MAY be omitted and then SHALL be 100000000. The value SHALL be an integer in 1..100000000. The decoded program SHALL be at most 1176 bytes. A larger program SHALL be rejected before a QUIC connection opens, with the named error `program_too_large`. An out-of-range budget SHALL be rejected the same way, with the named error `invalid_budget`, and SHALL NOT be sent to the guest.

The host SHALL send one RFL1 run on one bidirectional stream: 24-byte header, magic `RFL1`, kind 0, status 0, reserved bytes zero, an 8-byte big-endian correlation id, the budget as an 8-byte big-endian integer, then the program bytes. It SHALL pin the guest certificate with the spawn pin before sending that frame. A pin mismatch SHALL fail with the named error `peer_key_refused` and SHALL send no RFL1 payload.

The response SHALL be JSON `{"ok": true, "transport_status": <0|2|3>, "reply_b64": "<standard base64>"}`. `reply_b64` SHALL be the reply payload only. The host SHALL NOT decode Lean. Transport status 0 SHALL return HTTP 200, including a Lean budget-exhaustion payload, which the image also marks status 0. Transport status 2 SHALL return the named error `reply_too_large` and an empty `reply_b64`. Transport status 3 SHALL return the named error `invalid_budget` and an empty `reply_b64`. The host deadline SHALL be 60 seconds from the start of the handshake. Silence, including a frame the guest drops with no reply, SHALL be the named error `unikernel_timeout`.

The optional message `id` SHALL be the RFL1 correlation id when the caller supplies one. It SHALL NOT consult the mailbox and SHALL NOT suppress a second send. The CLI SHALL be `mj message --budget <n> <id> <program-file>`. It SHALL print the decoded reply bytes to stdout on transport status 0 and SHALL print a named error on stderr with no stdout bytes otherwise. MCP SHALL take the same `program_b64` and `budget` fields and SHALL return the same JSON object.

Only one exchange SHALL run at a time for a guest. A second message that arrives while the first exchange is open SHALL get the named error `unikernel_busy` and SHALL NOT send a packet.

`exec`, `connect`, `snapshot`, `done`, `doctor`, `ticket`, and `url` on this kind SHALL return the named error `unikernel_unsupported`.

#### Scenario: Factorial

- GIVEN a ready unikernel guest, the peer pin for homoiconic `793b583`, and the bytes of `examples/factorial.hom` from that commit
- WHEN `mj message --budget 100000000 <id> <that file>` runs
- THEN stdout is byte-for-byte the payload produced by that commit's `reply run 100000000 examples/factorial.hom`, and the HTTP body has `transport_status` 0

#### Scenario: Wrong peer key

- GIVEN a ready unikernel guest whose spawn pin differs in one byte from the image certificate
- WHEN a message is posted
- THEN the response is `peer_key_refused` and the guest serial log shows no program evaluation for that request

#### Scenario: Budget exhaustion is a status-0 payload

- GIVEN a ready unikernel guest and the bytes of `examples/forever.hom` from homoiconic `793b583`
- WHEN `mj message --budget 5000 <id> <that file>` runs
- THEN stdout matches that commit's `reply run 5000 examples/forever.hom`, `transport_status` is 0, and a later factorial message to the same guest still returns the factorial payload

#### Scenario: Second message while one is open

- GIVEN an exchange already open on a unikernel guest
- WHEN a second message is posted
- THEN the second response is `unikernel_busy` and the first exchange still returns its reply

#### Scenario: Oversize program and silence

- GIVEN a ready unikernel guest
- WHEN the program is 1177 bytes
- THEN the response is `program_too_large` and no QUIC connection is opened
- WHEN a well-framed run receives no reply for 60 seconds
- THEN the response is `unikernel_timeout`

### Requirement: Stop removes the tap and the scope, and restart does not resume

`mj kill` on a unikernel guest SHALL stop the hypervisor and remove that guest's TAP and systemd scope. Restart and resume SHALL NOT restore a unikernel guest from a rootfs or a snapshot and SHALL NOT replay a program. The restart policy for this kind SHALL be `:never`. A later start SHALL be a new spawn.

An operator restart through the Linux resume path SHALL return the named error `unikernel_restart_refused` and SHALL NOT boot the guest.

#### Scenario: Kill

- GIVEN a running unikernel guest
- WHEN `mj kill` completes
- THEN the TAP and the scope for that id are gone

#### Scenario: Restart

- GIVEN a stopped unikernel guest
- WHEN an operator calls the Linux resume or restart path for that id
- THEN the response is `unikernel_restart_refused` and no hypervisor process starts for that id

### Requirement: A guest that powers itself off is stopped, not resumed

When the hypervisor process exits on its own, the system SHALL mark that guest `:stopped` with reason `guest_exit` and SHALL withdraw readiness. Reconcile SHALL NOT treat a missing rootfs as data loss, SHALL NOT attach a vsock, and SHALL NOT boot the guest again. Cleanup SHALL remove a leftover TAP and scope. Health SHALL NOT require `guest_agent_ping` or a vsock connection for this kind.

#### Scenario: Fatal guest exit

- GIVEN a unikernel guest whose hypervisor process has exited
- WHEN Reconcile runs
- THEN the record is `:stopped` with reason `guest_exit`, the log does not contain `data lost — cannot resume` for that id, and no new hypervisor process exists for that id
