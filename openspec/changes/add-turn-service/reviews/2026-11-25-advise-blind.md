# add-turn-service — blind take

Reader: `fable-arch-review` (Claude Fable 5.2). Written 2026-11-25 from
`proposal.md`, the living specs `edge-relay` and `relay-room-auth`, the
relay precedent in code, and a read-only look at `45.76.77.97`. Written
before `design.md`, `tasks.md`, the spec delta, the ADR, the spikes and
`docs/plans/webrtc-turn-sfu.md` were opened. These are concerns the
contract has to have answered. They are not a competing design.

Host facts I am holding it against (read 2026-11-25):

- `iptables v1.8.10 (nf_tables)`, ufw active. `OUTPUT` policy is ACCEPT.
  `ufw-before-output` is `-o lo -j ACCEPT`, then
  `--ctstate RELATED,ESTABLISHED -j ACCEPT`.
- `INPUT` is `-i lo -j ACCEPT` first inside `ufw-before-input`.
- `rp_filter` is 2 (loose) on `all`, `default` and `enp1s0`.
- No global IPv6 address and no IPv6 default route. Link-local only.
  `ip6tables` `OUTPUT` policy is ACCEPT.
- Host addresses: `45.76.77.97`, `10.200.0.1`, `10.255.255.1` (`hostgw`),
  loopback. UDP bound on `0.0.0.0`: relay 443, two Iroh sockets in
  the ephemeral range. No rule in nat `OUTPUT`; published ports DNAT in
  `PREROUTING` only.
- Controller `epmd` is on `0.0.0.0:4369` and its distribution port on
  `0.0.0.0:46261` (TCP).
- `Mjolnir.API.Auth` gives every verified user JWT the whole scope set
  (`lib/mjolnir/api/auth.ex:51`, `:250`).

## What I would pin

1. The `OUTPUT` drops sit above the ufw jumps, and that position is
   asserted after install and after `ufw reload`. Appended, they are dead:
   a relayed packet to any host-local address leaves on `lo` and
   `ufw-before-output` accepts it first. `INPUT` accepts `-i lo`, so
   `OUTPUT` is the only netfilter chain between the daemon and a host
   service.
2. The kernel filter does not take its port range from the daemon's own
   configuration. A rule keyed on source ports `61000–65535` stops
   matching when the relay range in the daemon file changes, which is the
   file the first filter also lives in. Key it on "this uid, and not the
   listening port".
3. Host-local destinations are matched by kind (`addrtype LOCAL`), not by
   a list that has to name `45.76.77.97`. Add `0.0.0.0/8` (Linux delivers
   it to the host), `224.0.0.0/4`, `169.254.0.0/16`, `100.64.0.0/10`,
   `240.0.0.0/4`, broadcast.
4. IPv6 off is enforced three ways or it is assumed: the daemon file names
   no IPv6 relay address and the unit fails if one is detected, the unit
   cannot open `AF_INET6`, and `ip6tables` drops everything from the uid.
5. A tenant bound at the mint. eturnal counts allocations per username.
   Every mint is a new username, and every signed-in user holds every
   scope. Without a mint-side cap one account takes all 4,536 relay ports.
6. The owner comes from the verified `sub` through `mint_owner/1` and
   nowhere else, on both routes, with the operator and sites principals
   refused as the room mint refuses them.
7. What an expired credential can still do is a number in the spec:
   credential life, plus the longest allocation life the daemon grants,
   and whether a Refresh with an expired username is refused.

## What I would refuse

- "Two independent filters" as written if either one is a single point:
  both are configured by one deploy script, and one of them reads its
  port range from the other's file.
- A `--turn` that opens 3478 before the drops are in place, or removes
  the drops before the process is gone.
- Room and participant labels in a username that crosses the network in
  clear text, unless something needs them there.
- Any sentence that says the IPv4-mapped or IPv6 peer classes are refused
  by the blacklist. A 443 from an address-family check is not that.

## One tradeoff

The WebRTC gateway will sit on the host's own public address, and a
relay-only browser reaches it through this daemon. Either both filters
deny the host's public address now and the gateway change opens one UDP
port in both, or the hole is cut now for a port that does not exist yet.
I would deny now and say so, and accept that the gateway change re-opens
this contract and its advise.

## Questions for the evidence

- S2: was the capture taken with ufw active and the rule position the
  one production will have? Morphie is Arch.
- S1 expiry: is "expired" a refused Allocate, a refused Refresh, or a
  closed allocation?
- What does eturnal bind for Erlang distribution on the packaged build,
  and who can read the cookie?
- Is the unauthenticated STUN answer rate-limited, and what does it
  carry (`SOFTWARE`)?
