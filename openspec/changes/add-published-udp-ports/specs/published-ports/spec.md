# published-ports

## ADDED Requirements

### Requirement: A VM publishes UDP ports by kernel NAT

The system SHALL accept `published_ports` on HTTP spawn, `mj spawn --publish-udp`, and MCP spawn: a list of `{host_port, guest_port}` with `protocol` `udp`. `guest_port` SHALL default to `host_port`. For each entry the host SHALL DNAT a UDP datagram that arrives on the public interface for the public address and `host_port` to the guest's address and `guest_port`, and replies SHALL return to the sender from the public address and `host_port`. The translation SHALL be iptables rules. The system SHALL NOT run a userspace proxy for it. The rules SHALL NOT depend on the guest kind. For kind `unikernel`, `guest_port` MAY be `quic`, which is that guest's QUIC port.

The public interface SHALL be `published_port_interface` when set, and otherwise the interface of the IPv4 default route. The public address SHALL be that interface's IPv4 address, read when the rules are written. No address is fixed in code.

#### Scenario: A datagram reaches the guest and the reply returns

- GIVEN a host with `published_port_range` 20000-20099 and a running Linux guest spawned with `{host_port: 20001, guest_port: 4433}` that echoes UDP on 4433
- WHEN another machine sends a datagram to the host's public address on UDP 20001
- THEN the guest receives it on 4433 and the sender receives the echo from the host's address and port 20001

#### Scenario: Nothing else is opened

- GIVEN that guest
- WHEN a datagram arrives on the public interface for a guest port that is not published
- THEN no rule of this capability accepts it

#### Scenario: The public address changes

- GIVEN a running guest with a published port
- WHEN the public interface gets a different IPv4 address
- THEN within one sync interval the rules for the old address are removed and rules for the new address are written, old ones first

### Requirement: Published ports are part of the VM's stored configuration

The system SHALL store the list in `spawn_config` and SHALL write the rules again on resume, on reboot, on Reconcile, on adoption of a live guest, on dormant restore and on thaw. A stored record with no `published_ports` field SHALL resume with none. A stored entry that cannot be read SHALL be dropped, and the VM SHALL still resume.

#### Scenario: A record from before this change

- GIVEN a `:running` record whose `spawn_config` has no `published_ports`
- WHEN Reconcile resumes it
- THEN the VM boots and no rule is written for it

#### Scenario: Resume after a restart

- GIVEN a VM spawned with `{host_port: 20001, guest_port: 4433}`
- WHEN the service restarts and the VM is resumed or adopted
- THEN the same three rules exist for it, and `GET /api/vms/:id` lists the port

### Requirement: The host operator decides what may be published

Publishing SHALL be disabled unless `published_port_range` is configured. With a range, any caller that may spawn MAY publish a host port inside it. The system SHALL refuse, before any VM process starts: a port outside 1..65535, a protocol other than `udp`, a repeated host port, more entries than `published_ports_max_per_vm`, a host port outside the range, a host port in `published_port_reserved`, a host port that a socket on the host has bound for UDP, and a host port held by another VM. A VM SHALL hold its host ports while it has a stored record of any intent, a dormant entry, or a live process. Two spawns that ask for the same free port at the same time SHALL NOT both get it.

#### Scenario: Unconfigured host

- GIVEN a host with no `published_port_range`
- WHEN a spawn asks for a published port
- THEN the response is 403 `published_ports_disabled` and no VM process starts

#### Scenario: Reserved port

- GIVEN a range that contains 7222
- WHEN a spawn asks for host port 7222
- THEN the response is 403 `host_port_reserved`

#### Scenario: Port of another VM

- GIVEN a VM that holds host port 20001, running or stored
- WHEN a second spawn asks for 20001
- THEN the response is 409 `host_port_published`, the holder's id is not in the response, and the first VM's rules are unchanged

#### Scenario: Port the host uses

- GIVEN a host process with a UDP socket bound to 20005
- WHEN a spawn asks for host port 20005
- THEN the response is 409 `host_port_bound_by_host`

### Requirement: Rules do not outlive the VM

Every rule SHALL carry the comment `<tap_prefix>publish:<vm_id>`. When a VM stops, is killed, goes dormant, or fails to boot, the system SHALL remove every rule with its comment, whatever address the rule was written with. When the service detaches from a guest that keeps running, the rules SHALL stay. The startup sweep SHALL remove the rules of every id that has no `:running` record, and SHALL leave rules whose comment has another `tap_prefix`. If the record store cannot answer, the sweep SHALL keep the rule.

#### Scenario: Kill

- GIVEN a running guest with a published port
- WHEN `mj kill` completes
- THEN `iptables -S` in nat `PREROUTING` and filter `FORWARD` shows no rule with that VM's comment, and the host port can be published by another VM

#### Scenario: The service dies without stopping the VM's process cleanly

- GIVEN rules for a VM id that has no stored record
- WHEN the service starts
- THEN the sweep removes those rules

#### Scenario: A second instance on the same host

- GIVEN rules tagged `mj-publish:<id>` and a test instance whose `tap_prefix` is `mjt-`
- WHEN the test instance runs its sweep
- THEN those rules are still present
