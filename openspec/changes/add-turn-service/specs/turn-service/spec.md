# turn-service (delta)

Capability added by `add-turn-service`. Nothing here is folded.

## ADDED Requirements

### Requirement: TURN is its own service and deploy.sh --turn is the only switch
The host SHALL run TURN as `mjolnir-turn`, user `mjolnir-turn`, config directory `/etc/mjolnir-turn/` mode `0755` root:root. The binary SHALL be eturnal 1.12.x, unmodified. `:turn_enabled` SHALL default to false and `:turn_host` SHALL default to unset. `deploy.sh --turn` SHALL be the only operation that installs, starts, stops, or removes the unit, the `mjolnir-turn` firewall rules, and the uid rate cap. With both `:turn_enabled` true and `:turn_host` a non-empty hostname it SHALL install and start. Otherwise it SHALL stop and remove them. A deploy without `--turn`, and a restart of `mjolnir`, `mjolnir-gateway`, or `mjolnir-relay`, SHALL leave the unit and its rules as they were.

The unit SHALL set `STUN_SERVICE=false`. It SHALL set the relay IPv4 address to the host address this deploy already uses for the public interface, not to a discovered address. It SHALL NOT listen on 5349. It SHALL listen on UDP 3478 and TCP 3478. Relay allocations SHALL use UDP ports 61000 through 65535 only. The Erlang distribution port SHALL stay on `127.0.0.1`.

#### Scenario: TURN is off
- GIVEN `:turn_enabled` is false
- WHEN `deploy.sh --turn` runs
- THEN no `mjolnir-turn` unit is installed, nothing listens on 3478, and no iptables rule with comment `mjolnir-turn` remains

#### Scenario: Another deploy does not touch TURN
- GIVEN `mjolnir-turn` is active
- WHEN a deploy runs without `--turn`
- THEN the `mjolnir-turn` process id is unchanged and its rules are unchanged

### Requirement: Relayed packets cannot enter host, sidecar, or guest addresses
eturnal `blacklist_peers` SHALL be `recommended` plus the host's public IPv4 address and `::ffff:0:0/96`. `recommended` is eturnal 1.12.3's list: `127.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, `::1/128`, `64:ff9b::/96`, `0100::/64`, `fc00::/7`, `fe80::/10`, `ff00::/8`. eturnal also always blocks `0.0.0.0/8`, `::/128`, `2001::/32`, and `2002::/16`.

Independently, iptables (and ip6tables for the IPv6 prefixes) SHALL drop OUTPUT packets whose uid is `mjolnir-turn`, whose source port is in 61000–65535, and whose destination is in that same set, each rule commented `mjolnir-turn`. The rules SHALL be added only after the unit is active and removed when the unit is removed. Matching the relay source port is required so a STUN reply from port 3478 to a client is not dropped by these rules.

A host-wide rate cap SHALL apply to the `mjolnir-turn` uid on the same deploy. The number is the operator knob `:turn_rate_mbit`, default 100.

`deploy.sh --turn` SHALL refuse to install when `61000–65535` overlaps `:published_port_range` or `net.ipv4.ip_local_port_range`. Published-port reservation SHALL include 3478.

#### Scenario: The daemon refuses a sidecar peer
- GIVEN an authenticated allocation
- WHEN the client sends CreatePermission for `10.200.0.1`
- THEN the response is 403 Forbidden and no packet to `10.200.0.1` is sent

#### Scenario: The kernel drop still holds with the daemon filter emptied
- GIVEN `blacklist_peers` does not include `10.0.0.0/8` and the uid rules are installed
- WHEN the client sends a payload toward `10.200.0.1`
- THEN the DROP counter for that rule increases and a capture on `dummy-mjolnir` shows no packet

### Requirement: Credentials name the verified owner and expire
The controller SHALL mint a TURN REST credential: password is base64 of HMAC-SHA1 over the username, keyed by a secret from `/var/lib/mjolnir/turn-mint/current` (mode `0600`, root:root). The username SHALL be `<unix seconds>:<class>.<owner id>` with `<class>` one of `c1` or `g1`. A `c1` username minted with a room SHALL append `.<room>.<participant>`. `<owner id>` SHALL be `Mjolnir.Deploy.Owner.mint_owner/1` of the verified `sub`. A caller-supplied owner header or body field SHALL be ignored. Segments SHALL match the room mint's segment rule.

`POST /api/relay/rooms/:room/participants/:participant/token` SHALL include `ice_servers` when TURN is configured: the TURN URLs for `:turn_host` on UDP 3478 and TCP 3478, a `c1` username, and the credential. The field SHALL be absent when TURN is not configured. The rest of that response SHALL be unchanged.

`POST /api/turn/credentials` SHALL require scope `turn:relay`, SHALL refuse operator, sites, and capability principals the way the room mint does, SHALL return `Cache-Control: no-store`, and SHALL mint a `g1` username. The log line SHALL carry the sub, the owner, the class, and the expiry. It SHALL NOT carry the secret or the credential.

eturnal SHALL be configured with `strict_expiry: true` and every secret currently in the overlap set. A new Allocate or a Refresh with an expired username SHALL be rejected. An allocation created before expiry MAY continue until its TURN lifetime. The mint SHALL set the username expiry no later than the room token expiry for `c1`, and no later than 3600 seconds for `g1`. The implementation SHALL also send a TURN LIFETIME on the client side of the documented examples no longer than that, and the threat text SHALL state that a client who already holds an allocation can keep sending until the allocation lifetime (observed default 600 seconds) even after Refresh starts failing.

`scripts/turn-mint-secret.sh` SHALL install a new secret beside the old one, reload the daemon so new mints and new Allocate requests accept both, and SHALL drop the old secret only after the overlap (allocation lifetime plus 60 seconds). A reload SHALL NOT be specified as dropping live allocations until a test shows whether eturnal's reload does that.

#### Scenario: The owner is the verified sub
- GIVEN a user principal whose `sub` maps to owner A
- WHEN the client posts `/api/turn/credentials` with a body or header naming owner B
- THEN the username contains owner A and does not contain owner B

#### Scenario: An expired username cannot allocate or refresh
- GIVEN a username whose timestamp is in the past
- WHEN the client sends Allocate, and WHEN a client who allocated before that timestamp sends Refresh after it
- THEN both are rejected and the log does not contain the credential

#### Scenario: TURN is not configured
- GIVEN `:turn_enabled` is false
- WHEN a room token is minted
- THEN the response has no `ice_servers` field
