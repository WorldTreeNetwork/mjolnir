## MODIFIED Requirements

### Requirement: Unikernel boot has no rootfs and no agent
<!-- base: 7b0196ffd957dcf11b539d326c97b92c485f8056 openspec/specs/unikernel-guest/spec.md -->

For kind `unikernel` the boot path SHALL skip the rootfs clone, guest-agent injection, virtiofsd, and the vsock wait. It SHALL start the given ELF as the Cloud Hypervisor kernel with exactly 1 vCPU and 512 MiB. A `--memory` value other than 512 SHALL be rejected before boot. The kernel command line SHALL be exactly these five words and no others: `reflect.ip=<guest> reflect.port=<udp> reflect.quic_port=<quic> reflect.allow=<names> reflect.space=<space>`, using the address allocated for that TAP. `<names>` SHALL be this host's client name followed by the spawn's `allow` names, comma-separated, none twice.

Spawn of kind `unikernel` MAY take `space`: the cells each run on the guest may make (homoiconic `add-space-budget`). It SHALL be an integer from 1 to `:unikernel_space_max` (host configuration, default 4000000), and SHALL default to 4000000, the image's own default for a 512 MiB guest. Any other value SHALL be rejected with the named error `invalid_space` before a process starts. `<space>` SHALL be that value, written on every boot, so that the limit a guest runs under is the one recorded. `spawn_config`, the HTTP response, `mj info` and MCP SHALL carry it as `space`. `mj spawn` SHALL take it as `--space <cells>` and both MCP `spawn_vm` implementations as `space`.

The entity key SHALL reach the guest as the Cloud Hypervisor payload `initramfs`: a file `<socket_dir>/<vm_id>.entity-key` of exactly the 32 key bytes, created with mode 0600 so that no other user can read it at any time. The file SHALL be removed once the guest is ready, on every boot failure, when the guest stops, and when the BEAM detaches from a guest whose boot has not finished.

Readiness SHALL be the serial line `reflect: quic <quic>` in the existing file-mode serial log, together with the line `reflect: entity <name>` where `<name>` is the name of the spawn's key. A serial line `reflect: entity` with any other name, or readiness with no such line, SHALL fail the boot with the named error `entity_name_mismatch`. A serial line `reflect: no entity key`, `reflect: the entity key is not 32 bytes` or `reflect: the entity key is all zero` SHALL fail the boot without waiting for the boot deadline. The system SHALL NOT open a TCP server on the guest and SHALL NOT send a program on `reflect.port`.

`reflect.port` is still required by the image, but a guest with a QUIC word answers nothing on it, ping included (homoiconic `e9a4c86`). The only door into these guests is the QUIC port, and only for the names in `reflect.allow`. An image built before homoiconic `e9a4c86` has a built-in key, prints no `reflect: entity` line and does not work with this system. An image built before homoiconic `7efea06` does not know `reflect.space` and does not work with this system.

#### Scenario: Boot reaches the QUIC port

- GIVEN a Reflect ELF from homoiconic `3122521`, a kernel path inside the allow-list, and an entity key
- WHEN the unikernel guest becomes ready
- THEN no rootfs subvolume and no virtiofsd process exist for that guest, the payload `initramfs` is that guest's key file, the command line is only the five `reflect.*` words with this host's client name first in `reflect.allow` and `reflect.space=4000000` last, the machine has 1 vCPU and 512 MiB, the serial log contains `reflect: entity` followed by the name of the key and `reflect: quic` followed by the configured port, and the key file no longer exists

#### Scenario: The guest presents another name

- GIVEN a guest whose serial log shows `reflect: entity` with a name other than the name of the spawn's key
- WHEN the boot waits for readiness
- THEN the boot fails with `entity_name_mismatch`, and the key file is removed

#### Scenario: Memory other than 512

- GIVEN kind `unikernel` and `--memory` set to a value other than 512
- WHEN spawn is requested
- THEN the response is the named error `unikernel_memory` and no hypervisor process starts

#### Scenario: A space out of range

- GIVEN kind `unikernel` and `space` 0, or one more than `:unikernel_space_max`, or a value that is not an integer
- WHEN spawn is requested
- THEN the response is the named error `invalid_space` and no hypervisor process starts

#### Scenario: A space given at spawn

- GIVEN kind `unikernel` and `space` 100000
- WHEN the guest becomes ready
- THEN its command line ends `reflect.space=100000`, and its `spawn_config` and `mj info --json` carry `space` 100000

### Requirement: The host opens one QUIC exchange per message
<!-- base: 7b0196ffd957dcf11b539d326c97b92c485f8056 openspec/specs/unikernel-guest/spec.md -->

The Mjolnir BEAM on the guest's host SHALL open the QUIC v1 socket on that guest's TAP. `mj` SHALL only call the HTTPS API. It SHALL NOT open a socket to the guest address.

`POST /api/vms/:id/messages` for this kind SHALL read a JSON body `{"program_b64": "<standard base64>", "budget": <integer>}` and SHALL ignore a mailbox `payload`. `budget` MAY be omitted and then SHALL be 100000000. The value SHALL be an integer in 1..100000000. The decoded program SHALL be at most 1176 bytes. A larger program SHALL be rejected before a QUIC connection opens, with the named error `program_too_large`. An out-of-range budget SHALL be rejected the same way, with the named error `invalid_budget`, and SHALL NOT be sent to the guest.

The host SHALL send one RFL1 run on one bidirectional stream: 24-byte header, magic `RFL1`, kind 0, status 0, reserved bytes zero, an 8-byte big-endian correlation id, the budget as an 8-byte big-endian integer, then the program bytes. The handshake SHALL be mutual: the host SHALL present this host's client key, and SHALL accept only a guest whose name is the guest's `entity` before it sends its key or that frame. A guest that presents another name SHALL fail with the named error `peer_key_refused` and SHALL be sent no RFL1 payload. A handshake the guest never answers (it does not allow the client's key, or it is gone) SHALL be the named error `unikernel_timeout`. The host SHALL acknowledge the reply before the exchange ends.

The host's client SHALL answer a Retry as homoiconic's `quic.zig` `onRetry` does (homoiconic `unikernel-net`, "A full first-flight pool answers with a Retry"): it SHALL take at most one, send its ClientHello again at once with the Retry's token, and refuse a guest whose transport parameters do not name the Retry's source ID. The vendored `native/reflect_quic/quic.zig` SHALL be homoiconic's file at the commit NOTICE names, unmodified. A message SHALL therefore be served while other hosts hold every first-flight slot of the guest.

The response SHALL be JSON `{"ok": true, "transport_status": <0|2|3>, "reply_b64": "<standard base64>", "outcome": "<name>"}`. `reply_b64` SHALL be the reply payload only. The host SHALL NOT decode Lean values. `outcome` SHALL name the tag of the reply envelope (homoiconic `wire-bytes`, "A bounded run reply has a byte form") from the payload's first two bytes only: `82 00` `value`, `81 01` `budget`, `81 02` `refused`, `82 03` `unbound`, `81 04` `wrong`, `81 05` `fault`, `81 06` `unrepresentable`, `81 07` `space`, and `unknown` for any other bytes. Transport status 0 SHALL return HTTP 200, including a Lean budget-exhaustion payload and a space payload, which the image also marks status 0; these are outcomes of the program, not transport errors. Transport status 2 SHALL return the named error `reply_too_large` and an empty `reply_b64`. Transport status 3 SHALL return the named error `invalid_budget` and an empty `reply_b64`. Neither carries `outcome`. The host deadline SHALL be 60 seconds from the start of the handshake. Silence, including a frame the guest drops with no reply, SHALL be the named error `unikernel_timeout`.

The optional message `id` SHALL be the RFL1 correlation id when the caller supplies one. It SHALL NOT consult the mailbox and SHALL NOT suppress a second send. The CLI SHALL be `mj message --budget <n> <id> <program-file>`. On transport status 0 it SHALL print the decoded reply bytes, and nothing else, to stdout, SHALL print `mj: outcome <name>` on stderr when the outcome is not `value`, and SHALL exit 0. Otherwise it SHALL print a named error on stderr with no stdout bytes. MCP SHALL take the same `program_b64` and `budget` fields and SHALL return the same JSON object, `outcome` included.

Only one exchange SHALL run at a time for a guest. A second message that arrives while the first exchange is open SHALL get the named error `unikernel_busy` and SHALL NOT send a packet.

`exec`, `connect`, `snapshot`, `done`, `doctor`, `ticket`, and `url` on this kind SHALL return the named error `unikernel_unsupported`.

#### Scenario: Factorial

- GIVEN a ready unikernel guest from homoiconic `3122521` and the wire bytes produced by `reply source examples/factorial.hom` from homoiconic `793b583`
- WHEN `mj message --budget 100000000 <id> <that file>` runs
- THEN stdout is byte-for-byte the payload produced by `reply run 100000000 factorial-793b583.wire`, stderr has no outcome line, the HTTP body has `transport_status` 0 and `outcome` `value`, and the exchange used this host's client key

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
- THEN stdout matches `reply run 5000 forever-793b583.wire` (`81 01`), stderr says `mj: outcome budget`, `transport_status` is 0, and a later factorial message to the same guest still returns the factorial payload

#### Scenario: A run that passes its space

- GIVEN a ready unikernel guest with the default space and the wire bytes of `def deep x = [x, ...deep x]` applied to 0, made by `reply source` at homoiconic `3122521`
- WHEN `mj message --budget 100000000 <id> <that file>` runs
- THEN stdout is `81 07`, equal to that build's `reply run 100000000`, stderr says `mj: outcome space`, `outcome` is `space` and `transport_status` 0, and the guest then answers factorial in the same boot

#### Scenario: The first-flight pool is full

- GIVEN a ready unikernel guest, and a second address on the host that floods it with new first flights so that it answers Initials with Retries
- WHEN a factorial message is sent
- THEN it is answered with the factorial payload within one second, while the `e9a4c86` client, which ignores a Retry, is not answered while the flood lasts
- WHEN four clients with a key the guest does not allow stall their handshakes, holding the first-flight pool, and a factorial message is sent
- THEN it is answered within one second

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

### Requirement: A release carries the Reflect helpers

Every release that deploy builds, `--app-only` included, SHALL contain `priv/reflect-quic-client` (from `native/reflect_quic/host.zig`) and `priv/reflect-entity` (from `native/reflect_quic/entity-tool.zig`), built with Zig 0.16.0 before `mix release` by one script, `scripts/build-reflect-quic.sh`. A build that fails SHALL fail the release before cutover. Neither binary SHALL be tracked by Git.

#### Scenario: A fresh host

- GIVEN a host where nobody has built the helpers by hand
- WHEN `scripts/deploy.sh <host> --app-only` completes
- THEN the active release's `priv/` holds both helpers, and a unikernel spawn passes its preflight

### Requirement: The entity key leaves the request at parse time

The HTTP API SHALL remove `entity_key` from a request's `body_params` and `params` as soon as the body is parsed, and SHALL hold it only as a closure (`Mjolnir.Unikernel.entity_key_fun/1`), so that no later crash report, which may print the `conn` (Bandit logs a crash with `Exception.format/3`, which prints a `FunctionClauseError`'s arguments), holds the key text.

#### Scenario: A spawn request after parsing

- GIVEN an HTTP spawn body with an `entity_key`
- WHEN the body has been parsed
- THEN `inspect(conn)` does not contain the key text, and the spawn still receives the key
