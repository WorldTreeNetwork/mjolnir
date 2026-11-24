# unikernel-guest (delta)

## MODIFIED Requirements

### Requirement: Spawn selects a guest kind

The system SHALL accept guest kind `linux` or `unikernel` on HTTP spawn, `mj spawn`, and MCP spawn, and SHALL persist that kind in `spawn_config`. An omitted kind, including a persisted `spawn_config` that has no kind, SHALL be `linux`. Kind `unikernel` SHALL require a kernel path under the configured `unikernel_kernel_prefixes` allow-list and an entity key, and SHALL NOT require a base image or a snapshot. A kernel path outside that allow-list SHALL be rejected before a process starts. Kind `linux` SHALL keep the current rootfs, agent, virtiofs, and vsock boot.

The entity key SHALL be `entity_key`: the entity's 32-byte Ed25519 seed as base58 (Bitcoin alphabet, no checksum, each leading zero byte written `1`). The caller, the entity's owner, SHALL supply it; the system SHALL NOT make a key for a guest. A spawn of kind `unikernel` with no `entity_key` SHALL be rejected with the named error `entity_key_required`. A value that is not canonical base58 of exactly 32 bytes, or that is 32 zero bytes, SHALL be rejected with `entity_key_invalid`. Both SHALL be rejected before a process starts.

Spawn MAY take `allow`: a list of at most 7 entity names, each base58 of 32 bytes, none twice. Any other value SHALL be rejected with `allow_invalid` before a process starts. These are entities other than this host that may also complete a QUIC handshake with the guest, for example through a published port.

An entity's name SHALL be the 32 bytes Blake3 of the dCBOR of `{"alg": "ed25519", "key": <the Ed25519 public key>}`, written as base58 (homoiconic `unikernel/entity.zig`; identikey's fingerprint). `spawn_config`, the HTTP response and MCP SHALL carry the guest's name as `entity` and the `allow` list. They SHALL NOT carry the key. A persisted `spawn_config` that holds an older `peer_pin` SHALL be read without error.

#### Scenario: Linux spawn is unchanged

- GIVEN a spawn request with no kind
- WHEN the guest boots
- THEN the boot path clones a rootfs, injects the agent, starts virtiofsd, and waits for vsock as it does today

#### Scenario: Unikernel spawn records the kernel and the entity name

- GIVEN kind `unikernel`, a kernel path inside the allow-list, and an entity key
- WHEN the guest becomes ready
- THEN `spawn_config` stores kind `unikernel`, that kernel path, `entity` equal to the name of that key, and the `allow` list, and no stored record, response, log line or event holds the key

#### Scenario: Two keys and one key

- GIVEN two unikernel guests spawned with two different keys, and a third spawned later with the first key
- WHEN each becomes ready
- THEN the first two report two different `entity` names, and the third reports the same name as the first

#### Scenario: No entity key

- GIVEN kind `unikernel` and a kernel path inside the allow-list, with no `entity_key`
- WHEN spawn is requested
- THEN the response is the named error `entity_key_required` and no hypervisor process starts

#### Scenario: Kernel path outside the allow-list

- GIVEN kind `unikernel` and a kernel path outside `unikernel_kernel_prefixes`
- WHEN spawn is requested
- THEN the response is the named error `kernel_not_allowed` and no hypervisor process starts

### Requirement: Unikernel boot has no rootfs and no agent

For kind `unikernel` the boot path SHALL skip the rootfs clone, guest-agent injection, virtiofsd, and the vsock wait. It SHALL start the given ELF as the Cloud Hypervisor kernel with exactly 1 vCPU and 512 MiB. A `--memory` value other than 512 SHALL be rejected before boot. The kernel command line SHALL be exactly these four words and no others: `reflect.ip=<guest> reflect.port=<udp> reflect.quic_port=<quic> reflect.allow=<names>`, using the address allocated for that TAP. `<names>` SHALL be this host's client name followed by the spawn's `allow` names, comma-separated, none twice.

The entity key SHALL reach the guest as the Cloud Hypervisor payload `initramfs`: a file `<socket_dir>/<vm_id>.entity-key` of exactly the 32 key bytes, created with mode 0600 so that no other user can read it at any time. The file SHALL be removed once the guest is ready, on every boot failure, and when the guest stops.

Readiness SHALL be the serial line `reflect: quic <quic>` in the existing file-mode serial log, together with the line `reflect: entity <name>` where `<name>` is the name of the spawn's key. A serial line `reflect: entity` with any other name, or readiness with no such line, SHALL fail the boot with the named error `entity_name_mismatch`. A serial line `reflect: no entity key`, `reflect: the entity key is not 32 bytes` or `reflect: the entity key is all zero` SHALL fail the boot without waiting for the boot deadline. The system SHALL NOT open a TCP server on the guest and SHALL NOT send a program on `reflect.port`.

`reflect.port` is still required by the image, but a guest with a QUIC word answers nothing on it, ping included (homoiconic `e9a4c86`). The only door into these guests is the QUIC port, and only for the names in `reflect.allow`. An image built before homoiconic `e9a4c86` has a built-in key, prints no `reflect: entity` line and does not work with this system.

#### Scenario: Boot reaches the QUIC port

- GIVEN a Reflect ELF from homoiconic `e9a4c86`, a kernel path inside the allow-list, and an entity key
- WHEN the unikernel guest becomes ready
- THEN no rootfs subvolume and no virtiofsd process exist for that guest, the payload `initramfs` is that guest's key file, the command line is only the four `reflect.*` words with this host's client name first in `reflect.allow`, the machine has 1 vCPU and 512 MiB, the serial log contains `reflect: entity` followed by the name of the key and `reflect: quic` followed by the configured port, and the key file no longer exists

#### Scenario: The guest presents another name

- GIVEN a guest whose serial log shows `reflect: entity` with a name other than the name of the spawn's key
- WHEN the boot waits for readiness
- THEN the boot fails with `entity_name_mismatch`, and the key file is removed

#### Scenario: Memory other than 512

- GIVEN kind `unikernel` and `--memory` set to a value other than 512
- WHEN spawn is requested
- THEN the response is the named error `unikernel_memory` and no hypervisor process starts

### Requirement: The host opens one QUIC exchange per message

The Mjolnir BEAM on the guest's host SHALL open the QUIC v1 socket on that guest's TAP. `mj` SHALL only call the HTTPS API. It SHALL NOT open a socket to the guest address.

`POST /api/vms/:id/messages` for this kind SHALL read a JSON body `{"program_b64": "<standard base64>", "budget": <integer>}` and SHALL ignore a mailbox `payload`. `budget` MAY be omitted and then SHALL be 100000000. The value SHALL be an integer in 1..100000000. The decoded program SHALL be at most 1176 bytes. A larger program SHALL be rejected before a QUIC connection opens, with the named error `program_too_large`. An out-of-range budget SHALL be rejected the same way, with the named error `invalid_budget`, and SHALL NOT be sent to the guest.

The host SHALL send one RFL1 run on one bidirectional stream: 24-byte header, magic `RFL1`, kind 0, status 0, reserved bytes zero, an 8-byte big-endian correlation id, the budget as an 8-byte big-endian integer, then the program bytes. The handshake SHALL be mutual: the host SHALL present this host's client key, and SHALL accept only a guest whose name is the guest's `entity` before it sends its key or that frame. A guest that presents another name SHALL fail with the named error `peer_key_refused` and SHALL be sent no RFL1 payload. A handshake the guest never answers (it does not allow the client's key, or it is gone) SHALL be the named error `unikernel_timeout`. The host SHALL acknowledge the reply before the exchange ends.

The response SHALL be JSON `{"ok": true, "transport_status": <0|2|3>, "reply_b64": "<standard base64>"}`. `reply_b64` SHALL be the reply payload only. The host SHALL NOT decode Lean. Transport status 0 SHALL return HTTP 200, including a Lean budget-exhaustion payload, which the image also marks status 0. Transport status 2 SHALL return the named error `reply_too_large` and an empty `reply_b64`. Transport status 3 SHALL return the named error `invalid_budget` and an empty `reply_b64`. The host deadline SHALL be 60 seconds from the start of the handshake. Silence, including a frame the guest drops with no reply, SHALL be the named error `unikernel_timeout`.

The optional message `id` SHALL be the RFL1 correlation id when the caller supplies one. It SHALL NOT consult the mailbox and SHALL NOT suppress a second send. The CLI SHALL be `mj message --budget <n> <id> <program-file>`. It SHALL print the decoded reply bytes to stdout on transport status 0 and SHALL print a named error on stderr with no stdout bytes otherwise. MCP SHALL take the same `program_b64` and `budget` fields and SHALL return the same JSON object.

Only one exchange SHALL run at a time for a guest. A second message that arrives while the first exchange is open SHALL get the named error `unikernel_busy` and SHALL NOT send a packet.

`exec`, `connect`, `snapshot`, `done`, `doctor`, `ticket`, and `url` on this kind SHALL return the named error `unikernel_unsupported`.

#### Scenario: Factorial

- GIVEN a ready unikernel guest from homoiconic `e9a4c86` and the wire bytes produced by `reply source examples/factorial.hom` from homoiconic `793b583`
- WHEN `mj message --budget 100000000 <id> <that file>` runs
- THEN stdout is byte-for-byte the payload produced by `reply run 100000000 factorial-793b583.wire`, the HTTP body has `transport_status` 0, and the exchange used this host's client key

#### Scenario: The guest is not the one expected

- GIVEN a ready unikernel guest, and a host exchange that expects the name of another key
- WHEN the exchange runs
- THEN the result is `peer_key_refused`, no RFL1 payload is sent, and the guest still answers this host's next message

#### Scenario: A client key the guest does not allow

- GIVEN a ready unikernel guest, and a host exchange that presents a key whose name is not in the guest's `reflect.allow`
- WHEN the exchange runs
- THEN the result is `unikernel_timeout`, and a client presenting a key whose name is in the spawn's `allow` list is answered

#### Scenario: Budget exhaustion is a status-0 payload

- GIVEN a ready unikernel guest and the wire bytes produced by `reply source examples/forever.hom` from homoiconic `793b583`
- WHEN `mj message --budget 5000 <id> <that file>` runs
- THEN stdout matches `reply run 5000 forever-793b583.wire`, `transport_status` is 0, and a later factorial message to the same guest still returns the factorial payload

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

## ADDED Requirements

### Requirement: The entity key is the owner's

An entity's key SHALL be supplied and kept by its owner. The system SHALL NOT generate, escrow, export or return an entity's key, and SHALL NOT store it in `spawn_config`, a StateStore record, a log line, an event, an HTTP response or MCP output. Mjolnir and its host hold the key while the guest runs, because the launcher chose the guest's memory and can read it; the system SHALL keep the key on disk only in the 0600 boot file, and only for the duration of the boot. In memory it SHALL be held so that inspecting spawn options or VM state does not print it. Nothing SHALL make the key recoverable only through Mjolnir: an owner who stops using this host keeps the key and the entity's name, and can compute the name offline (`mj entity name <key-file>`).

`mj spawn` SHALL read the key from a file of exactly 32 bytes (`--entity-key-file`), send it as base58, and SHALL NOT print it. No client path SHALL put the key in a process's arguments.

#### Scenario: The key is kept nowhere

- GIVEN a unikernel guest spawned with an entity key, now ready
- WHEN its StateStore record, its serial log, its hypervisor log and the VM state are read
- THEN none of them contains the key, as base58, as hex or as raw bytes, and the boot key file does not exist

#### Scenario: A boot that fails

- GIVEN a unikernel spawn whose boot fails after the key file was written
- WHEN the failure is handled
- THEN the key file does not exist

### Requirement: The host has one QUIC client key

The host's BEAM SHALL hold one Ed25519 key as a QUIC client, in a file of exactly 32 bytes at `:reflect_client_key` (default `<state_dir>/reflect-client.key`). When the file does not exist the system SHALL create it from 32 strongly random bytes, with mode 0600 before any byte is written. A file that is not 32 bytes, or is all zero, SHALL fail a unikernel spawn with `reflect_client_key_invalid` before a process starts. This key's name SHALL be the first name in every guest's `reflect.allow`. It is this host's identity to its guests, not any entity's.

#### Scenario: First use

- GIVEN no client key file
- WHEN the first unikernel guest is spawned
- THEN the file exists with mode 0600 and 32 bytes, its name is first in that guest's `reflect.allow`, and a later spawn uses the same file
