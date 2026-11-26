# add-turn-service

> **ACTIVE BUILD** — node `mjolnir-rurh.10` (turn-service). Duke put TURN in scope on 2026-11-25. This change is node A (`turn-service`) and node B (`turn-credentials`) from `docs/plans/webrtc-turn-sfu.md`. No product code until an advise accept.

## Why

A WebRTC client that cannot reach another peer needs a TURN server it can name as an ICE server. Mjolnir does not have one. A TURN server on this host is also a proxy that sends from the host itself, so a relayed packet to `10.200.0.1`, a guest address, or loopback walks past the inbound firewall. The service has to exist, and it has to be unable to make that walk.

## What

- Host service `mjolnir-turn`, process eturnal 1.12.x (Apache-2.0), own systemd unit and unprivileged user. UDP and TCP 3478 for STUN/TURN. Relay allocations on UDP `61000–65535`. RFC 6062 TCP relaying is not implemented by this eturnal and stays off. TLS on 5349 stays off. TCP 443 stays the gateway's.
- Off by default (`:turn_enabled`, `:turn_host`). Installed, changed, or removed only by `deploy.sh --turn`. That flag does not restart the controller, the gateway, or `mjolnir-relay`.
- Credentials are the TURN REST ephemeral scheme. The controller holds the shared secret. Username is `<unix-expiry>:<class>.<owner id>` plus `.<room>.<participant>` for a call credential. The room mint response gains `ice_servers` when TURN is configured. `POST /api/turn/credentials` serves a general credential behind scope `turn:relay`. Owner comes from `Mjolnir.Deploy.Owner.mint_owner/1` on the verified `sub`.
- Two egress filters, both required. eturnal `blacklist_peers`, and iptables `OUTPUT` rules matched on the daemon uid and the relay source-port range, comment `mjolnir-turn`, removed with the unit. A host-wide rate cap on that uid is installed with the same flag.
- Secret file `/var/lib/mjolnir/turn-mint/current` mode `0600` root. `scripts/turn-mint-secret.sh` overlaps the old and new secrets. The daemon is told both.

**Rigor:** architecture (security). **Blast:** new public UDP and TCP listener, a shared secret on the host, a way to proxy packets from the host if either filter is wrong.

Design: [`design.md`](design.md). Draft ADR: [`docs/decisions/0018-turn-service.md`](../../../docs/decisions/0018-turn-service.md). Spikes: [`spikes/verdict.md`](spikes/verdict.md).

## Impact

- Capabilities: ADDED `turn-service` (daemon, filters, credentials, mint).
- ADRs: draft `docs/decisions/0018-turn-service.md`.
- Code, after accept: `lib/mjolnir/turn/` (mint), route and scope in the API, `systemd/mjolnir-turn.service`, `scripts/deploy.sh` (`--turn`), `scripts/turn-mint-secret.sh`, config keys. No change to `native/mjolnir_gateway` or `native/mjolnir_relay`.
- Host: system user `mjolnir-turn`, `/etc/mjolnir-turn/` root-owned, firewall openings for 3478, OUTPUT drops, a rate cap.
- Not changed: guest images, the gateway's TCP 443, the relay's UDP 443, metering (`mjolnir-rurh.4`).

## User journey & surfaces

No new UI because this change ships the service and the credential API. A browser client is a later node.

- Operator enables TURN, sets the public name, deploys with `./scripts/deploy.sh <host> --turn`.
- `systemctl status mjolnir-turn` is active. A signed-in user with `turn:relay` receives `ice_servers` from `POST /api/turn/credentials`. A room mint includes the same shape for the call.
- Off: the unit is absent, 3478 is closed, and no rule commented `mjolnir-turn` remains.
- Failed: with no secret file the unit does not start, and the firewall rules are not installed.
- Acceptance of the service itself is the spike pair: a real TURN client allocates, and a relay toward `10.200.0.1` is refused by the daemon and, with the daemon filter emptied, dropped by iptables with an empty capture on the target interface.

## Preparation

- Inputs: `docs/plans/webrtc-turn-sfu.md` node A and node B. Spikes S1 and S2 on morphie, 2026-11-26. Precedent: `edge-relay`, `relay-room-auth`, ADR 0016.
- Outcome: this contract. Product code waits for advise.

## Out of scope

- TURN over TLS on TCP 443 through the gateway (`turn-tls-443` in the plan).
- TLS on 5349.
- The WebRTC gateway / SFU, WHIP, WHEP, and the browser page.
- Per-owner byte caps and billing (`mjolnir-rurh.4`). Session byte lines are a scrape point only.
- IPv6 relay allocations. The daemon may bind no IPv6 relay address.
- Hairpin of a relayed packet into a guest's published UDP port (plan spike S10).
- DNS for `turn.worldtree.network`. No A record exists. The owner creates it, aimed at `45.76.77.97`, the same address as `media-relay.worldtree.network`.
