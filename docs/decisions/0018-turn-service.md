# ADR 0018 — TURN service

**Status:** Draft. Duke has not accepted it. Implementation waits on an advise pass over `openspec/changes/add-turn-service/`.
**Change:** [`add-turn-service`](../../openspec/changes/add-turn-service/proposal.md)
**Spikes:** [`verdict`](../../openspec/changes/add-turn-service/spikes/verdict.md)
**Plan:** [`webrtc-turn-sfu.md`](../plans/webrtc-turn-sfu.md) nodes A and B.

## One screen

1. `mjolnir-turn` is eturnal 1.12.x, its own user and unit. Not the gateway, not the relay, not a guest.
2. Off until `:turn_enabled` and `:turn_host` are set. `deploy.sh --turn` is the only install and remove path.
3. UDP and TCP 3478. Relay UDP 61000–65535, above the kernel ephemeral range 32768–60999. No 5349. No TCP 443.
4. The controller mints TURN REST credentials. The username names the owner from the verified `sub`. Room mint grows `ice_servers`. General use is `POST /api/turn/credentials` and scope `turn:relay`.
5. Two filters. The daemon's peer blacklist, and iptables OUTPUT drops for uid `mjolnir-turn` from the relay port range only, comment `mjolnir-turn`. A host-wide rate cap rides the same flag.
6. The shared secret is root-only and is not the relay signing key. Rotation overlaps two secrets. A live allocation surviving that reload is not yet shown.
7. `strict_expiry` stops Refresh and a new Allocate. It does not stop Send on an allocation that already exists (observed, eturnal 1.12.3, default lifetime 600 seconds).
8. Do not enable on production until `turn.worldtree.network` points at `45.76.77.97` and Duke says so. The name has no A record.

## Decisions recorded as recommendations

These match the plan unless the spike forced a change. They are not accepted until Duke says so.

**D1.** eturnal, not coturn, not a Pion daemon, unless advise rejects D7 or D8 and wants a hard lifetime cap or per-packet `c1` reach.

**D2.** Own unit and user. `deploy.sh --turn` only. `STUN_SERVICE=false` so the stock wrapper does not query `stun.conversations.im`.

**D3.** Ports as in the one screen. `3478` becomes a reserved published port. The relay range must not overlap the ephemeral range or `:published_port_range`.

**D4.** TURN REST, HMAC-SHA1, username `expiry:class.owner…`. Owner from `Mjolnir.Deploy.Owner.mint_owner/1`. Secret `/var/lib/mjolnir/turn-mint/current`.

**D5.** Blacklist is eturnal's `recommended` plus the host public address plus `::ffff:0:0/96`. Kernel rules match uid and source port 61000–65535. A uid-only rule drops replies to LAN and loopback clients; S2 showed that.

**D6.** Host-wide cap, default 100 Mbit/s, knob `:turn_rate_mbit`. Per-owner caps stay on `mjolnir-rurh.4`.

**D7.** (Spike.) Credential expiry is not allocation end. Say so in the threat text. Do not claim `strict_expiry` closes calls.

**D8.** (Spike.) `c1` does not restrict peers. One blacklist for every credential.

**D9.** IPv6 relay address is `none`. Mapped peers on the IPv4 allocation we do offer are refused with 443 before the blacklist runs.

**D10.** Production stays off. DNS is an owner prerequisite, not something this change creates.
