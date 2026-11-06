## ADDED Requirements

### Requirement: Proxy guest is a separate network class

A proxy-class guest SHALL NOT install a default route and SHALL NOT configure a public DNS resolver. The proxy process on that guest SHALL be able to connect to loopback and to `10.200.0.1/32`, and SHALL NOT be able to connect to any other remote address. That guest SHALL NOT publish an Iroh relay address.

An ordinary guest SHALL keep `mjolnir-network-setup`, including its default route and its public resolvers, the `Mjolnir.Health.GuestNetwork` probe of `1.1.1.1`, and the shell endpoint built with `presets::N0`. Healing an ordinary guest SHALL NOT install a default route or a public resolver on a proxy-class guest.

The unmodified `identikey-api-proxy.service` SHALL NOT be the egress boundary for this class. Its `StateDirectory` symlink exits in `Journal::open` before bind, and its localhost-only address allowlist refuses `10.200.0.1`.

#### Scenario: Proxy class stays off the public network

- GIVEN a proxy-class guest booted with `enable_iroh` false, the proxy `mjolnir-network-setup`, and the data-dir drop-in
- WHEN a process confined as the proxy connects to `127.0.0.1`, to `10.200.0.1`, and to `1.1.1.1`
- THEN the loopback and host-API connects succeed
- AND the public connect fails
- AND the guest has no default route, no public resolver, and no relay address

#### Scenario: Ordinary guests stay unchanged

- GIVEN an ordinary guest booted from `ubuntu-24.04` with Iroh left at its default
- WHEN its network setup and shell endpoint start
- THEN it has a default route, the public resolvers, and a shell relay path

#### Scenario: Ordinary guest with Iroh disabled stays ordinary

- GIVEN an ordinary `ubuntu-24.04` guest spawned with `enable_iroh` false
- WHEN it boots
- THEN it keeps the stock `mjolnir-network-setup`, a default route, and the public resolvers
- AND it publishes no relay address
- AND it is not a proxy-class guest

### Requirement: Proxy class identity is the base image

The authoritative class signal SHALL be `base_image`. A proxy-class image is one whose root contains the proxy `mjolnir-network-setup` and the data-dir drop-in. `enable_iroh` SHALL NOT be that signal. Spawning a proxy-class image SHALL set `enable_iroh` false and SHALL refuse the spawn when `enable_iroh` is true. An ordinary image spawned with `enable_iroh` false SHALL keep ordinary networking.

`spawn_config` SHALL persist `base_image` and `enable_iroh` (`Mjolnir.VM.build_running_record/1`). The supported resume for this node SHALL be `Mjolnir.VM.reboot/1`, which reads those stored values through `resume_opts/1`. A stored `enable_iroh` false SHALL stay false. A missing `enable_iroh` SHALL remain the ordinary default, true. Snapshot restore and dormant restore SHALL be outside this node.

#### Scenario: Resume keeps the proxy image and the false flag

- GIVEN a running proxy-class guest whose stored `spawn_config` has the proxy `base_image` and `enable_iroh` false
- WHEN `Mjolnir.VM.reboot/1` resumes that record
- THEN the resumed guest uses that same `base_image` and `enable_iroh` false
- AND it still has no default route, no public resolver, and no relay address

#### Scenario: Proxy image with Iroh requested does not boot

- GIVEN a spawn whose `base_image` is a proxy-class image and whose `enable_iroh` is true
- WHEN the host accepts the spawn
- THEN the spawn is refused
- AND no guest is left running

### Requirement: Proxy health treats isolation as healthy and drift as repairable

`GuestNetwork` for a proxy-class guest SHALL report ok when there is no default route, the resolver is not a public resolver, the `10.200.0.1/32` route is present, and a TCP connect to `10.200.0.1` port 4000 succeeds. That ok result SHALL NOT install a default route.

A missing `10.200.0.1/32` route, a present default route, or a public resolver SHALL NOT be ok. The level-2 heal SHALL run the proxy `mjolnir-network-setup` again and SHALL leave the guest with no default route, no public resolver, and the host `/32` route. The reachability target SHALL be `10.200.0.1` port 4000. A missing connect tool SHALL be degraded, not ok, and SHALL NOT count as a successful connect.

#### Scenario: Intact pin is healthy

- GIVEN a proxy-class guest with no default route, resolver `127.0.0.1`, and a route to `10.200.0.1/32`
- WHEN a TCP connect to `10.200.0.1` port 4000 succeeds
- THEN `GuestNetwork` is ok
- AND the heal does not change the route or the resolver

#### Scenario: Level-2 heal repairs drift

- GIVEN a proxy-class guest whose default route or public resolver has returned, or whose `10.200.0.1/32` route is missing
- WHEN a level-2 heal runs
- THEN the guest ends with no default route, no public resolver, and a route to `10.200.0.1/32`
- AND the proxy process still cannot connect to `1.1.1.1`

### Requirement: Acceptance fails closed

The local acceptance command SHALL assert the combined boundary and SHALL exit non-zero when any assertion fails. A failed cgroup join, a missing guest inspection, a non-zero guest exit, or a connect result other than the one asserted SHALL fail the command. Route checks SHALL match the address `10.200.0.1` exactly, not as a substring. The resolver list SHALL be exactly `127.0.0.1`. The unit status SHALL be the whole word `active`. The command SHALL assert that the default route and the host `/32` are gone before the level-2 heal, and SHALL read `spawn_config` from the spawned guest's own state file. It SHALL reboot that guest through the supported resume path and SHALL re-check the pin, the stored false flag, and unit confinement. After reboot it SHALL read the live guest detail and SHALL fail unless `enable_iroh` is false and both `ticket` and `iroh_addr` are present and empty. The reboot acknowledgement itself SHALL require `ok`, `rebooted`, and `guest_healthy`. It SHALL NOT restart `mjolnir`. Cleanup SHALL delete only guests whose stored metadata marks them as owned by that invocation. It SHALL cover a proxy boot, confinement of the proxy unit while a default route exists, and an ordinary `ubuntu-24.04` guest spawned with `enable_iroh` false. Negative confinement SHALL be measured from the proxy unit against root in the same guest, so a public-connect failure is not only a missing route. Root SHALL open `1.1.1.1` and one other non-allowlisted IPv4 address while a default route exists. The command SHALL fail if the unit opens either. The guest kernel on this host is built with `CONFIG_IPV6` unset, so a non-loopback IPv6 connect cannot succeed for root. The command SHALL record that attempt and SHALL fail if the unit opens it. Offline fixtures SHALL show that a missing host `/32`, an added public resolver, and an inactive unit each fail the checker. The running release still treats a default route as healthy, so this live command does not claim the class-aware probe. Implementation tests SHALL assert that probe: an intact pin is ok, and a default route, a public resolver, or a missing host `/32` is not ok.

#### Scenario: Acceptance command rejects a broken pin

- GIVEN the local acceptance command
- WHEN the proxy unit can connect to `1.1.1.1` while a default route exists, or the heal leaves the host `/32` missing
- THEN the command exits non-zero

#### Scenario: Unmodified stock unit is not the boundary

- GIVEN the stock `identikey-api-proxy.service` with `DynamicUser` and `IPAddressAllow=localhost` only
- WHEN that unit is started without one of the repairs in `design.md`
- THEN it is not treated as a passing proxy-class boot
