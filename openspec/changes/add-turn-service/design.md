# add-turn-service — design

Nodes A and B of `docs/plans/webrtc-turn-sfu.md`. Spikes: [`spikes/verdict.md`](spikes/verdict.md). Choices below were the architect's recommendations. Duke has not confirmed them one by one. Each is an ASK.

## ASK

1. **Server.** Recommend eturnal 1.12.x. Spike S1 allocated, refused expired Allocate and Refresh, refused the listed IPv4 peers with 403, and refused TCP transport with 442. Fallback remains a small Pion daemon if a later review wants per-packet `c1` reach or a hard cap on allocation lifetime. Do not switch to coturn.
2. **Unit.** Recommend `mjolnir-turn`, user `mjolnir-turn`, `/etc/mjolnir-turn/`, off unless `:turn_enabled` and `:turn_host` are set, changed only by `deploy.sh --turn`.
3. **Ports.** Recommend UDP and TCP 3478, relay UDP 61000–65535, no 5349, no TCP 443. Confirmed against the kernel: ephemeral `32768–60999` on morphie and, read-only, on `45.76.77.97`. `MJOLNIR_PUBLISHED_PORT_RANGE` is unset in production `/etc/mjolnir/env`. `3478` is not reserved in `config/config.exs` today; the implementation adds it.
4. **Credentials.** Recommend TURN REST (HMAC-SHA1, username `expiry:class.owner…`), `ice_servers` on the room mint, `POST /api/turn/credentials` with scope `turn:relay`, secret overlap script in the style of `scripts/relay-mint-key.sh`.
5. **Filters.** Recommend both layers. Refine the kernel layer: match uid **and** source port `61000–65535`. A uid-only drop also drops STUN replies to any client whose address is in the list. The first S2 attempt showed that (Allocate to `127.0.0.1` timed out, the `127/8` counter moved).
6. **Rate.** Recommend a host-wide cap of 100 Mbit/s on the uid (`:turn_rate_mbit`), from the first deploy. No per-owner cap in this change.
7. **Production enable.** Recommend no. DNS for `turn.worldtree.network` does not exist. Do not start the unit on `45.76.77.97` until Duke says so and the name resolves to that address.

## What the spike changed in the architect's text

- `strict_expiry` does **not** close a live allocation. Refresh and a new Allocate fail. Send on the same allocation still counted a second packet after the timestamp (`s1c-sessions.txt`, `Sent: 2 packets`), and the session was still listed. The threat table below says so. The architect's sentence "strict_expiry ends refresh" is what we saw. The eturnal doc's "close established calls" is not what 1.12.3 did in this lab.
- `c1` and `g1` are labels in the username. eturnal has one peer list. `c1` is not confined to a future media port. Per-packet class reach is the Pion fallback, not this daemon.
- IPv4-mapped peers on an IPv4 allocation come back `443 Peer Address Family Mismatch` before the blacklist. Still a refusal. The blacklist entry `::ffff:0:0/96` is there for an allocation that does not take that path. IPv6 relay stays off, so we do not offer that allocation.
- The stock container wrapper probes `stun.conversations.im` unless `STUN_SERVICE=false`. The unit sets that. YAML `relay_ipv4_addr` alone did not stop the probe.

## Credential

```
username   = "<unix>:<class>.<owner id>[.<room>.<participant>]"
credential = base64(HMAC-SHA1(secret, username))
```

`<class>` is `c1` (room mint) or `g1` (`POST /api/turn/credentials`). `<owner id>` is `Mjolnir.Deploy.Owner.mint_owner/1` on the verified `sub`. `.` is the separator because owner, room, and participant segments cannot contain it. The HMAC covers the whole username.

Secret on disk: `/var/lib/mjolnir/turn-mint/current`, and during overlap `/var/lib/mjolnir/turn-mint/previous`, both `0600` root:root. The controller (root) reads them. The daemon's config in `/etc/mjolnir-turn/eturnal.yml` lists the same secrets. That file is `0640` root:`mjolnir-turn` so the daemon can read it and the gateway user cannot. The two secrets are not the relay's signing key. A TURN process that leaks its config can mint TURN credentials. It cannot mint room tokens.

Rotation: `scripts/turn-mint-secret.sh` writes a new `current`, keeps the old as `previous`, rewrites the YAML list to both, and reloads `mjolnir-turn`. New mints use `current`. Allocate accepts either, which S1 showed for two configured secrets. After the overlap (600 seconds, the observed default allocation lifetime, plus 60 seconds) the script removes `previous` from the YAML and reloads again. Whether that reload drops live allocations is **not** known. The implementation task has to show a live allocation surviving a reload before this script is used on a host that has users. Until that observation exists, the script's reload is a documented risk, not a promise.

Logs: eturnal already logs the username (owner, class, expiry, room, participant) and byte counts. It did not log the secret or the base64 credential in the captured log. The controller log line matches the room mint: sub, owner, class, expiry. Never the secret, never the credential.

## Blacklist

Daemon (`blacklist_peers`): the keyword `recommended` (expanded in the spec from the 1.12.3 source) plus the host public IPv4 and `::ffff:0:0/96`.

`10.200.0.0/16` and every guest address the host uses today sit inside `10.0.0.0/8`, which `recommended` already contains. The host public address does not, so it is added. Multicast is `224.0.0.0/4` and `ff00::/8`. Link-local is `169.254.0.0/16` and `fe80::/10`. CGNAT is `100.64.0.0/10`.

Kernel: the same destinations, OUTPUT, uid `mjolnir-turn`, source port `61000:65535`, comment `mjolnir-turn`, IPv6 prefixes on ip6tables. No exception for a WebRTC edge port in this change. That exception was for a later node. Adding it now would open a hole before that port exists.

Rate cap: `nft` or `tc` on the uid, default 100 Mbit/s, knob `:turn_rate_mbit`. This was not spiked. The rule is part of the same install and remove path as the DROP rules.

## Threat table

| Who | Can | Cannot |
|---|---|---|
| Tenant, user principal, scope `turn:relay` | Mint a `g1` credential naming their own owner. Allocate and relay to a public address. Refresh until the username timestamp. Keep sending on an allocation that already exists until its TURN lifetime (observed default 600s) after that timestamp. | Mint a credential for another owner. Edit the owner in a username and still pass HMAC. Reach a blacklisted peer (403) or, if the daemon filter is off, get a relayed packet past the uid/port DROP. Read the secret. Mint a room token from this secret. |
| Tenant, scope `relay:join` only | Receive a `c1` username inside `ice_servers` when they mint a room token and TURN is on. Same relay reach as `g1`, because eturnal has one peer list. | Call `POST /api/turn/credentials`. Confine `c1` to a single host port. |
| Unauthenticated internet host | Send a STUN Allocate and receive 401. Send a STUN Binding if the daemon answers those (it is a STUN server on 3478). | Allocate, create a permission, or cause a relayed packet. Hold state on the 401 (architect's claim; not measured here). |
| Holder of an expired username, no prior allocation | Nothing beyond the unauthenticated host. Allocate returns 401. | Refresh a session they never created. |
| Holder of an expired username who already allocated | Send to peers they already have permission for, until the allocation lifetime. | Refresh. Create a new allocation. |
| Holder of another tenant's credential | Use it until the username timestamp for new allocations, and until the allocation lifetime for one they already created. It is a bearer token. | Change the owner, class, or expiry without failing HMAC. Reach a blacklisted peer. |

Quotas in this change: eturnal's compiled defaults (`max_allocations` 10, `max_permissions` 10 in the 1.12.3 YAML schema). The spike did not show whether those numbers are per username or per process. The implementation records which, and does not invent a per-owner byte cap. That cap is `mjolnir-rurh.4`. The host-wide rate cap is the abuse limit until then. Credential lifetime for `g1` is at most 3600 seconds. The allocation can outlive the username by the gap between Allocate and the TURN lifetime.

## Process

Same shape as the relay. `systemd/mjolnir-turn.service`, `User=mjolnir-turn`, `NoNewPrivileges=yes`, config and secret not writable by the user. `deploy.sh --turn` installs the package or the pinned image's extracted binary under `/usr/local/lib/mjolnir-turn/`, writes the unit, the YAML, the DROP rules, and the rate cap, and does not call `systemctl restart mjolnir`. Removing TURN deletes rules by the comment, the same way the relay deletes `mjolnir-relay`.

`STUN_SERVICE=false` is in the unit environment. `ETURNAL_RELAY_IPV4_ADDR` is the public address. `relay_ipv6_addr: none`.

Published ports: add `3478` to `:published_port_reserved`. `--turn` checks the relay range against `ip_local_port_range` and `:published_port_range` and refuses an overlap.

## Not covered

- TCP 443 and TLS 5349. No certificate work in this change.
- IPv6 relay allocations.
- Per-owner metering and per-owner deny.
- A guest's published UDP port as a legal peer (hairpin from the host). The DROP forbids it on purpose.
- Closing a live allocation at the username timestamp. eturnal 1.12.3 did not.
- Per-packet distinction between `c1` and `g1`.

## Licensing

eturnal is Apache-2.0 and stays its own process. Host code we write (mint, scripts, unit) is AGPL-3.0-or-later, like the rest of the host. We do not copy eturnal sources into the tree.

## Tests the implementation writes first

Each fails until the code exists. None of them are in the tree now, on purpose: this change stops at the contract.

- `test/mjolnir/turn/mint_test.exs` — owner from `sub`, header ignored, HMAC matches the username, expired timestamp, `c1` shape, `g1` shape, secret absent.
- `test/mjolnir/api/turn_credentials_test.exs` — scope `turn:relay`, wrong principal kind, `Cache-Control: no-store`, log without the credential, `ice_servers` present and absent on the room mint.
- A script test or a dry-run fixture for the iptables comment and the port-range overlap refusal, next to the relay's rule tests if those exist; otherwise `test/mjolnir/turn/rules_test.exs` over the pure rule builder. The kernel drop itself stays a lab observation (`spikes/evidence/s2-counters.txt`), not a `mix test`.
