# WebRTC on the call platform: TURN and SFU

**Status:** Design proposal for Duke. Not an OpenSpec change, not a contract. No code, no beads, no production change.
**Date:** 2026-11-25
**Epic:** `mjolnir-rurh` (platform-calls)
**Trigger:** Duke: "I'd like this also to act as a standard TURN and SFU for WebRTC."

Every factual claim carries one of three labels:

- **[R]** read today (2026-11-25) in the named source.
- **[H]** observed today on the production host `45.76.77.97` with read-only commands.
- **[M]** from memory, not checked today. Treat as a hypothesis.

## Goal

Mjolnir's call platform serves standard WebRTC clients as well as MoQ clients: it runs a TURN server (RFC 8656) that any WebRTC application can name as an ICE server, and it forwards multi-party media for WebRTC participants. Both reuse the owner, room and token model that the MoQ relay already has, and neither weakens the rule that the host holds no content key for a protected call.

## Current state

- `mjolnir-relay` is live at `media-relay.worldtree.network`: moq-relay at moq `4a6f52248`, WebTransport on UDP 443, its own Iroh endpoint, own process and user, off by default, changed only by `deploy.sh --relay`. [R `openspec/specs/edge-relay/spec.md`, ADR 0016]
- The controller mints room tokens at `POST /api/relay/rooms/:room/participants/:participant/token`: user principal with `relay:join`, owner from the verified `sub` (`Mjolnir.Deploy.Owner.mint_owner/1`), root `t/<owner>/<room>`, publish `<participant>/**`, subscribe `**`, EdDSA, default life 3600 s. The relay holds public keys only. [R `openspec/specs/relay-room-auth/spec.md`, `lib/mjolnir/relay/mint.ex`]
- Call encryption is in build (`add-call-e2ee`, ADR 0017): profile `moq-e2ee-01-wip`, a 32-byte secret in the invite fragment `#v=1&p=…&kid=…&k=…`, per-label context `mjolnir-call/v1/<owner>/<room>/<label>`, one secret per call. The platform cannot record, transcode or preview a protected call. [R ADR 0017, `design.md` D1, D3]
- The epic lists "TURN/WebRTC" and "Safari and iOS browsers" as non-goals (2026-11-20). [R `bd show mjolnir-rurh`] This plan reverses the first. The second has moved under it: Safari has WebTransport since 26.4. [R MDN browser-compat-data `api/WebTransport.json`]
- The relay has no TCP path. `config.web.ws = false` in `native/mjolnir_relay/src/main.rs:160`. [R] A participant on a network that blocks UDP cannot join a call today.
- Production host: 8 cores, 31 GiB RAM, one public IPv4 (`45.76.77.97` on `enp1s0`), no global IPv6 address, UDP 443 held by `mjolnir-relay`, TCP 80 and 443 held by `mjolnir-gateway`, kernel ephemeral range 32768–60999, `net.core.rmem_max` and `wmem_max` 212992. No `MJOLNIR_PUBLISHED_PORT_RANGE` is set there. No TURN or SFU binary is installed. [H]
- Several host services listen on all interfaces and rely on ufw's default-deny inbound policy to keep the internet out: the API on TCP 4000, epmd on 4369, Erlang distribution on a high port, Forgejo on 3000. [H `ss -tlnp`, `ufw status verbose`] This matters for TURN (see Q1, abuse).

### What is recorded about "coturn vs MoQ"

No document in `docs/decisions/`, `docs/LEARNINGS.md` or `openspec/changes/archive/` holds that comparison. [R grep for `coturn`, `TURN`, `SFU`, `webrtc`] What is recorded:

- The epic's non-goal line. [R]
- The first advise review of `add-call-e2ee`: "The original question was whether Mjolnir is a good home for real-time media over QUIC, MoQ and Iroh, with peers contributing bandwidth, as against bandwidth-heavy central SFUs," and its finding that relay fan-out is central bandwidth with the same shape as an SFU: N·(N−1)·b, 84 Mbit/s for eight people at 1.5 Mbit/s. What MoQ buys is no per-subscriber packet rewriting, drop decisions that work on ciphertext, one UDP port with no ICE, and one model for native and browser. [R `openspec/changes/add-call-e2ee/reviews/2026-11-23-advise.md:271-275`]
- An older initiative, `docs/plans/initiatives/option-c-dual-layer-architecture.md`, proposed a WebRTC data-channel mesh between VMs with ICE, STUN and TURN. It was never built. [R]

So the MoQ choice stands on the record as "media plane", and TURN/WebRTC stands as "excluded", with no written reasons for the exclusion. Nothing below contradicts a recorded reason.

### The finding that shapes this plan

The pinned moq revision already contains a WebRTC edge. [R local cargo checkout of `4a6f522`]

- `rs/moq-webrtc` (0.3.12, MIT OR Apache-2.0) is a WHIP and WHEP gateway between WebRTC peers and MoQ broadcasts, built on str0m. WHIP is RFC 9725. WHEP is `draft-ietf-wish-whep-05` (2026-10-15). [R crate manifest, `doc/bin/webrtc.md`, IETF datatracker]
- It negotiates Opus, H.264, H.265, VP8, VP9 and AV1 in both directions. All sessions share one UDP port, routed by ICE username fragment. [R `doc/bin/webrtc.md`, `src/server/mux.rs`]
- It is meant to be embedded: "To own the HTTP route and authorize requests yourself (resolving the broadcast name from a verified token), skip the routers and call `whip::accept` / `whep::accept` from your own handler." [R `src/lib.rs`]
- It can hold a WHIP publisher to a bandwidth cap: a `b=TIAS` line, REMB, then close. [R `src/rate.rs`]
- Upstream non-goals for it: TURN, data channels. [R `quest/m3/webrtc/README.md`]
- `moq-relay` can split its QUIC port: `Relay::webrtc()` hands ICE, DTLS and RTP datagrams that arrive on UDP 443 to an embedder. At the pin, `moq-webrtc` still binds its own socket (`Server::bind`), so nothing connects the two yet. [R `rs/moq-relay/src/relay.rs:446-455`, `rs/moq-webrtc/src/server/mod.rs:165`]
- `mjolnir-relay` already builds on `moq_relay::Relay`. [R `native/mjolnir_relay/src/main.rs:163`]

The gateway re-frames media. It turns RTP into MoQ frames through codec importers that parse the bitstream (H.264 and H.265 parameter sets, VP8 keyframe headers for catalog dimensions). [R `src/lib.rs` "Bitstream gotcha", `src/codec/vp8.rs`] It cannot carry media it cannot read.

## Q1. TURN

### Adopt or build

| | coturn | eturnal | Pion `turn` (small daemon we write) | webrtc-rs `turn` | Build from RFC 8656 |
|---|---|---|---|---|---|
| Version read today | 4.19.2, 2026-11-18 [R] | 1.12.3, 2026-09-17 [R] | v5 stable line; v6.0.0-rc.1, 2026-11-10 [R] | 0.17.3, 2026-11-07 [R crates.io] | — |
| License | BSD 3-clause text [R `LICENSE`] | Apache-2.0 [R] | MIT [R] | Apache-2.0 / MIT [R repo] | ours (AGPL) |
| Language | C | Erlang | Go | Rust | Rust |
| Shape | Daemon and config file | Daemon and YAML file | Library: "not a binary you deploy then configure" [R README] | Library | — |
| Ephemeral credentials (TURN REST scheme) | `use-auth-secret` [R man page via search] | Native, and several secrets at once for rotation [R eturnal.net/doc] | `AuthHandler` callback; we write the HMAC check [R `server_config.go`] | `AuthHandler` trait [M] | we write it |
| Peer address filter | `denied-peer-ip` [R search summary], `allowed-peer-ip` [M] | `blacklist_peers`, default `recommended` (Enable Security's list); `0.0.0.0/8`, `::/128`, `2001::/32`, `2002::/16` always blocked [R eturnal doc] | `PermissionHandler(clientAddr, peerIP)` [R] | [M] similar | we write it |
| Quota and rate | `user-quota`, `total-quota`, `max-bps`, `bps-capacity` [M] | `max_permissions` default 10; `max_bps` covers TCP and TLS client connections only [R] | `QuotaHandler(username, realm, srcAddr)`; rate limiting by wrapping the relay socket [R] | none built in [M] | we write it |
| Expiry | checked at allocation [M] | `strict_expiry: true` also refuses refresh after expiry [R] | ours | ours | ours |
| Metrics | Prometheus [M]; 4.19.0 labels the allocation gauge by protocol and family [R release notes] | `mod_stats_prometheus`, aggregate [R] | `EventHandler` lifecycle callbacks [R] | [M] little | ours |
| Client address behind a proxy | [M] PROXY protocol on TCP | `proxy_protocol` flag [R] | ours | ours | ours |
| Security record | 19 advisories published in 2026, among them a pre-auth heap disclosure, a session takeover and four that concern peer-address filtering (CVE-2026-27624, -53450, -73212, -73213) [R GitHub security advisories API] | none found today; 349 stars, so far less scrutiny [R] | none found today [M] | none found today [M] | none, and no review either |
| Fit here | New C daemon facing the internet. Ubuntu 24.04 packages an old 4.6 line [M], so we would build 4.19 ourselves | BEAM is a runtime this team already operates. Release tarball or apt repo [R README] | Go is already on the host for the Forgejo runner [R CLAUDE.md]. We own about 500 lines | Server side is little used [M]. webrtc-rs is moving to the sans-IO `rtc` crate [R crates.io] | Weeks of work, then we are the only reviewers |

**Recommendation: adopt eturnal.** It needs no code of ours, speaks the credential scheme natively, blocks the recommended ranges by default, and runs on a memory-safe runtime, which removes the heap-disclosure and overflow classes that fill coturn's 2026 advisory list. coturn's activity is a good sign for coturn, and its knobs are the richest, but that list also shows how much pre-auth parsing surface a C TURN server puts on the internet. If the spike shows eturnal cannot give per-owner quota or per-owner byte counts, the fallback is a small Pion `turn` daemon, not coturn, because the Pion hooks take the username and we need exactly that. Do not build one.

### Credentials

Use the TURN REST ephemeral scheme (`draft-uberti-behave-turn-rest-00`, 2014, expired, and still what coturn, eturnal and every browser path implement [R datatracker, eturnal doc]). The controller holds a shared secret and returns:

```
username   = "<exp unix seconds>:<class>.<owner id>.<room>.<participant>"
credential = base64(HMAC-SHA1(secret, username))
```

- `<owner id>` is the same canonical base58 id the room token uses, from `Mjolnir.Deploy.Owner.mint_owner/1` on the verified `sub`. `x-owner-id` and body fields are ignored, as in the room mint.
- `.` is the separator because no owner, room or participant segment can contain it (`[A-Za-z0-9_-]{1,64}` and base58).
- `<class>` is `c1` for a call credential and `g1` for a general one (see abuse, below). A general credential has no room: `g1.<owner id>.<label>`.
- The HMAC covers the whole username, so a tenant cannot edit the owner, the class or the expiry.

**What binding means for TURN.** A TURN allocation has no room. It is a UDP port that relays to peers. So "one tenant's credential cannot relay for another" reduces to three things, and the design gives each:

1. **Attribution.** Every allocation is logged and counted under the owner in its username. Tenant A cannot make tenant B pay.
2. **Reach.** No credential, of any tenant, can reach a guest address, a host sidecar or a host-only service. That is the deny rule below, and it does not depend on the tenant.
3. **Lifetime.** A call credential expires with its room token. `strict_expiry` ends refresh at that moment.

This is weaker than the relay's model in one respect. The relay verifies with public keys and holds no signing key. TURN's scheme is symmetric: the TURN daemon holds the same secret the controller mints with. A compromised TURN process can mint TURN credentials for any owner on that host. It cannot mint room tokens, because the two secrets are separate and must stay separate. The TURN secret lives at `/var/lib/mjolnir/turn-mint/` (root, `0600`) for the controller and in the daemon's root-owned config. Rotation overlaps two secrets, the way `scripts/relay-mint-key.sh` overlaps two public keys.

### Quota and abuse

A TURN server is a UDP proxy with a login. The risks, in order:

1. **Reaching inside.** A relayed packet leaves from the host itself. The host firewall filters what arrives from outside; it does not filter what the host sends to its own addresses. So a relay to `10.200.0.1` (sidecars), `10.255.255.1`, a guest address in `10.0.0.0/8`, loopback, or the host's own public address reaches services that ufw hides from the internet. [H listening sockets and ufw rules] Enable Security describes TURN relay abuse as server-side request forgery with more reach. [R search summary of enablesecurity.com]
2. **Free bandwidth.** A credential is a bearer token for relayed traffic until it expires.
3. **Floods before login.** Unauthenticated Allocate requests and STUN binding floods.

Controls, two layers deep for the first risk because coturn's four peer-filter advisories in one year show the daemon's own filter is the part that fails:

- **Daemon filter.** `blacklist_peers: recommended` plus the host's own addresses and guest ranges, the CGNAT range `100.64.0.0/10`, and the IPv4-mapped IPv6 forms.
- **Kernel filter by user.** The TURN daemon runs as its own user. iptables `OUTPUT` rules matched on that uid (`-m owner --uid-owner mjolnir-turn`), each tagged `mjolnir-turn` like the relay and published-port rules, drop anything it sends to loopback, private, link-local, CGNAT and the host's own addresses, with one exception: the WebRTC edge's media port. This holds even if the daemon's filter is bypassed. It is the same mechanism Mjolnir already uses for published ports (tagged rules that `Cleanup` and deploy can find and remove).
- **No TCP relaying.** RFC 6062 TCP allocations are off. Browsers use UDP relays even when they reach the TURN server over TCP or TLS [M], and a TCP relay toward the host's own address is what would reach the API, epmd or Forgejo.
- **Two credential classes.** `c1` (call) is minted with a room token and is meant to reach only the WebRTC edge on this host. `g1` (general) may reach public addresses and exists so a tenant's own WebRTC application can use Mjolnir as its ICE server. eturnal applies one peer policy to all users, so the class is enforced at the mint (who may get `g1`) and in accounting, not per packet. Per-packet class enforcement needs the Pion daemon.
- **Bandwidth.** eturnal's `max_bps` does not cover UDP clients. [R] Day one gets a host-wide cap on the TURN user's traffic (tc or nftables, by uid), a fixed relay port range, and a short credential life. Per-owner byte counts and caps arrive with `mjolnir-rurh.4`.
- **Mint rate limit.** Same bucket as the room mint, owed by `mjolnir-rurh.4`.
- **Floods.** `blacklist_clients` for known sources; eturnal answers unauthenticated Allocate with a 401 challenge and holds no state for it [M].

### Ports

| Port | Protocol | Holder | State |
|---|---|---|---|
| 443 | UDP | `mjolnir-relay`, QUIC and WebTransport | live [H] |
| 443 | TCP | `mjolnir-gateway`; adds TURN over TLS by server name | proposed |
| 80 | TCP | `mjolnir-gateway` | live [H] |
| 3478 | UDP and TCP | `mjolnir-turn`, STUN and TURN | proposed |
| 5349 | TCP | nobody | recommend not opening it |
| 61000–65535 | UDP | TURN relay allocations | proposed |
| 3479 | UDP | `mjolnir-rtc` media, one port | proposed, number open |
| 20000–20099 | UDP | published guest ports, where the operator set the range | existing, not set on production [H] |

- **Relay range.** eturnal's default is 49152–65535 [R], which overlaps this host's ephemeral range 32768–60999 [H]. 61000–65535 sits above it and above the published-port guidance ("keep the range below 32768" [R CLAUDE.md]). That is 4536 allocations at once.
- **Published ports.** `Mjolnir.PublishedPorts` already refuses a host port that a host UDP socket holds per `/proc/net/udp`, and a fixed reserved list. [R `lib/mjolnir/published_ports.ex:50`] Add 3478 and the media port to `:published_port_reserved`, and make `deploy.sh --turn` refuse a relay range that overlaps `:published_port_range`.
- **TURN over UDP 443** is not available: QUIC holds it. A second public IPv4 would give it back.
- **TURN over TLS on TCP 443.** This is the path that works from networks that allow only HTTPS. The gateway owns TCP 443 and already selects a certificate by server name (`SniCertResolver`, `native/mjolnir_gateway/src/tls.rs:258`), then reads the name after the handshake (`main.rs:1852`). [R] Three ways:

  | Option | What changes | Cost |
  |---|---|---|
  | (a) Gateway terminates TLS for the TURN name and pipes the plain TURN bytes to `127.0.0.1:3478` with a PROXY header | A branch after the handshake in the gateway. The gateway is already the certificate issuer. eturnal needs no TLS. | TURN-over-TLS sessions die when the gateway restarts. The gateway's ALPN list is `http/1.1` only [R `tls.rs:352`]; a client that offers only `stun.turn` would be refused, so browser behaviour must be captured first. |
  | (b) Gateway peeks at the ClientHello and passes the raw TLS stream to eturnal on 5349 | A peek-and-splice path before the acceptor, plus a certificate copy step for the TURN user like the relay's. | More gateway code in the hottest path. Same restart coupling. The gateway never sees TURN traffic, which gains little: TURN carries DTLS-SRTP, and TURN's password never crosses the wire. |
  | (c) Second public IPv4 for TURN, with its own TCP 443 and UDP 443 | No gateway change. `mjolnir-relay` must bind one address instead of `0.0.0.0`. | A monthly fee, and it does not exist on a mini-hoster's box with one address. |

  ALPN alone cannot route this: TURN has `stun.turn` (RFC 7443) but whether browsers send it is unverified [M]. Server name can.

  **Recommendation: (a), as its own node after plain TURN is live.** Advertise `turn:<host>:3478?transport=udp`, `turn:<host>:3478?transport=tcp` and `turns:<host>:443?transport=tcp`.

### Process model

Like the relay: unit `mjolnir-turn`, user `mjolnir-turn`, config in root-owned `/etc/mjolnir-turn/`, off by default (`:turn_enabled`, `:turn_host`), installed, started, stopped and removed only by `deploy.sh --turn`, firewall rules tagged `mjolnir-turn` added only after the unit is active. Restarting `mjolnir` or the gateway leaves plain TURN sessions up.

## Q2. SFU

"Standard" needs a definition first. WebRTC standardises the media path, not how a client asks a server for a room. The only IETF signalling for a server is WHIP (RFC 9725) for publishing and WHEP (a draft) for playing. Every conferencing SFU (LiveKit, mediasoup, Janus, Galene, Jitsi) has its own protocol and its own client library. So a "standard WebRTC SFU" is either WHIP/WHEP, or one product's protocol chosen for its client ecosystem.

| | License and fit with an AGPL host | Language and operations fit | Scale per core | Simulcast / SVC | End-to-end encryption | Recording hooks | Maintenance (read today) |
|---|---|---|---|---|---|---|---|
| **MoQ relay plus `moq-webrtc` edge** (WHIP/WHEP) | MIT OR Apache-2.0, linkable into our AGPL binaries [R] | Rust, already in the dependency tree at the pin. Own unit and user. One UDP port [R] | Unmeasured. Owed by a scale node | Reads simulcast layers on ingest [R `session.rs:437`]. Egress picks one rendition from the catalog [R `doc/bin/webrtc.md`]. No SVC [inference] | **None on the WebRTC leg.** The gateway parses the bitstream [R] | Any MoQ subscriber can record an open room; `moq-archive` and `moq-hls` sit in the same tree [R]. Must stay unshipped | Commits daily; breaking `feat(net)!` changes weekly; crate at 0.3.x [R GitHub commits] |
| **LiveKit** 1.13.11 (2026-10-25) | Apache-2.0, separate process [R] | Go, one binary, Redis optional for one node [R deployment doc]. Own JWT (API key and secret) [R] | 16 cores: 150 publishers and 150 subscribers at 720p, 85% CPU, 50 MB/s in, 93 MB/s out; 1 publisher to 3000 subscribers at 92% [R docs.livekit.io benchmark] | Both, plus per-subscriber layer choice [M] | Built in to every SDK. Keys never reach the server. Its own frame format, not RFC 9605 [R docs and `client-sdk-js/src/e2ee/constants.ts`] | Separate Egress service that joins as a participant [M] | 22k stars, pushed today, company-backed [R] |
| **mediasoup** rust-0.33.2 (2026-11-04) | ISC [R] | C++ worker with a Rust or Node API. A library: we write signalling and the client [R] | "over ~500 consumers" per worker, one worker per core [R mediasoup.org scalability] | Both [M] | Possible: forwards RTP without reading payloads [M] | Plain RTP out to ffmpeg or GStreamer [M] | Active [R] |
| **Janus** 1.4.4 (2026-11-23) | GPL-3.0, separate process [R] | C, plugin server, config files, its own API | Multi-threaded; no figure read today | Both [M] | Pass-through flag in plugins [R code search finds `e2ee` in `src/plugins`] | Built in, to disk [M] | Active [R] |
| **Galene** 1.2.2 (2026-11-09) | MIT [R] | Go, a whole application with its own groups, users and TURN [M] | "very moderate server resources" [R README]; no figure | Both [M] | None [M] | Built in, to disk [M] | One main author [M]; active [R] |
| **Our own on str0m** 0.26.0 (2026-11-22) | MIT [R] | Rust, sans-IO. Its `chat` example is a small SFU [R README] | Ours to prove | Ours to write, with bandwidth estimation and layer choice | By construction if it forwards RTP | None unless we add them | str0m is active [R]; the SFU would have one maintainer: us |
| **atm0s-media-server** 0.2.0-alpha.9 (2026-05-18) | MIT [R] | Rust on str0m, WHIP/WHEP and its own SDK [R] | — | [M] | — | Recording components in tree [R README] | Alpha; README says "refactoring-era state" [R] |
| **Jitsi Videobridge** | Apache-2.0 [R] | JVM, and needs Prosody and Jicofo beside it [M] | — | Both [M] | In Jitsi Meet [M] | Jibri [M] | Active [R] |
| **ex_webrtc** 0.18.0 (2026-10-26) | Apache-2.0 [R] | Elixir. In the controller's VM it would tie calls to controller cutovers; as its own node it is a second BEAM | Unverified | [M] partial | — | — | Active; its TURN sibling `rel` is stale since 2024 [R] |

Reading the table:

- Only the first row puts a WebRTC participant in the room a MoQ participant is already in.
- Only a forwarding SFU (LiveKit, mediasoup, Janus, our own) can carry a protected WebRTC call. Of those, LiveKit is the one that ships the client side too, on every platform.
- mediasoup and str0m fit the house style best (Rust sidecar) and cost the most: we would own signalling, a client library and, for str0m, the congestion and layer logic.
- Janus, Galene and Jitsi bring their own application model, storage or recording, which is more to switch off than to use.

## Q3. One room or two systems

| Option | What it is | Cost | Encryption |
|---|---|---|---|
| (a) Separate WebRTC rooms on a forwarding SFU; share auth, naming, TURN and metering | A second media plane. A room is MoQ or WebRTC, never both | A second server (Go if LiveKit), a second token format, a second client code path, a second scale and limits story. No MoQ participant can talk to a WebRTC participant | A protected WebRTC call is possible, with its own frame format and a second cryptographic review |
| (b) A bridge: WebRTC tracks republished into MoQ and back | `moq-webrtc` in front of the relay. One room, both kinds of client | Small: the code is at the pin. One PeerConnection per published or played participant. No data channels. Tracks upstream's churn | **The bridge reads the media.** WebRTC legs are plaintext at the host. A protected room cannot be bridged |
| (c) Replace MoQ for browsers with WebRTC | Drop the WebTransport client; browsers use an SFU | Discards the direction of `mjolnir-rurh.5` and `.9`. Loses hidden track names and catalogs, drop decisions on ciphertext, and the single-port, no-ICE path | Encoded-transform encryption only; more metadata exposed than MoQ exposes |

**What a bridge does to encryption.** A bridge that re-frames can keep content encrypted only if the encrypted frame is identical on both sides and the bridge can move it without reading it. Neither holds:

- `moq-e2ee` takes its nonce from the MoQ group identity and the frame's index in the group, and binds the track name, epoch and context into the key. Its draft says: "This profile is not SFrame: it has no SFrame header, no CTR field on the wire, and no per-object KID." [R `drafts/draft-lcurley-moq-e2ee.md:79-80`, `quest/m5/e2ee/README.md`] A WebRTC sender cannot know which group and index the gateway will assign.
- SFrame (RFC 9605) carries KID and CTR in a header on each frame, so it survives any transport. Its RTP payload format is still a draft (`draft-ietf-avtcore-rtp-sframe-03`, 2026-10-21). [R datatracker] No browser exposes a native SFrame transform that the compat data tracks. [R MDN browser-compat-data has no SFrame entry]
- The gateway's importers need plaintext codec headers. [R]

So the two sides **can share a credential and cannot share a frame format**. The 32-byte invite secret can feed two key derivations under different labels. A frame sealed for one side cannot be opened as the other. A protected call can span both transports only through an endpoint that holds the key, and the host must not be one. ADR 0017 already says a credential holder inside a guest is inside the host's boundary.

**Recommendation: (b) for open rooms, and (a) later, only if a protected WebRTC call is asked for.** A room is then one of two kinds:

- **Protected** (the default in the shipped client): MoQ only, `moq-e2ee`, host holds no key. Unchanged.
- **Open**: MoQ and WebRTC participants together. The host can read the media. The page must say so.

Nothing has to enforce the split. A WHEP request for a protected broadcast finds no catalog it can read and fails; upstream states this for any plaintext player. [R `quest/m5/e2ee/README.md`] A plaintext WHIP publish into a room of protected clients is ignored by them, because they render only authenticated instances. [R ADR 0017 item 2] Both are spike S7 before they are claims.

## Q4. End-to-end encryption for WebRTC calls

**What "the relay and host hold no content key" means for an SFU.** An SFU terminates DTLS-SRTP with each participant, so it always sees RTP headers and header extensions (audio level, orientation, layer structure), packet sizes and timing, and every signalling message: who is in the room, track names, mute state. Frame encryption in the browser hides only the codec payload, and usually leaves a few leading bytes clear so the SFU can find keyframes; LiveKit leaves 10 bytes of a VP8 keyframe, 3 of a delta frame and 1 of an Opus packet. [R `client-sdk-js/src/e2ee/constants.ts`] LiveKit's own documentation says signalling is not end-to-end encrypted. [R] That is more metadata than the MoQ relay sees, which gets opaque track names and an encrypted catalog. The ADR 0017 consequence carries over unchanged: no recording, transcoding, transcription or preview of a protected call by the platform.

**Browser support for the API** (`RTCRtpScriptTransform`, the standard encoded-transform interface) [R MDN browser-compat-data]:

| Browser | Since | Date |
|---|---|---|
| Safari, macOS and iOS | 15.4 | March 2022 [M] |
| Firefox, desktop and Android | 117 | August 2023 [M] |
| Chromium | 141 | October 2025 (MDN marks the feature Baseline from that month [R search summary]) |
| Chromium, older non-standard `createEncodedStreams` | 86 (`RTCEncodedVideoFrame`) [R] | October 2020 [M] |

So the API is in all three engines today. Native SFrame is in none that the compat data tracks; Firefox's bug for it is still open. [R search summary of Bugzilla 1715625] Any SFrame would run as script inside the transform.

**Reusing the credential and the invite link.** Yes for delivery, no for the profile.

- The invite fragment already names a profile (`p=`), and a client refuses a profile it does not support. A protected WebRTC call would be a second profile name with the same `kid` and `k` fields and the same one-secret-per-call rule.
- The per-label context carries over and should. LiveKit's key provider accepts per-participant keys. [R docs] Deriving each participant's key from the secret and `mjolnir-call/v1/<owner>/<room>/<label>` gives the same property ADR 0017's B1 fix gives MoQ: an SFU that relabels alice's track as bob's makes it undecryptable. That is spike S9, not a fact.
- It is a second cryptographic design, with its own review at the rigor `add-call-e2ee` had. It is not a configuration switch.

**Recommendation:** no protected WebRTC calls in this round. Protected calls stay MoQ. Safari now has WebTransport [R], so the browser gap that would have forced the issue is closing by itself.

## Q5. Auth reuse

- **Same route for a call participant.** `moq-webrtc` resolves the broadcast from a verified token by design [R `src/lib.rs`], and WHIP's own auth is `Authorization: Bearer <token>` [M]. The existing room token is that bearer. A WebRTC participant mints exactly what a MoQ participant mints. No new token type, no new signing key, no new scope: `relay:join` covers it.
- **The mint response grows one field.** `ice_servers`: the URLs, and a `c1` TURN username and credential that expire with the token. The route, the checks and their order do not change. When TURN is not configured the field is absent. A guest who holds only an invite link gets the TURN pair in the link beside the room token; ADR 0017 already treats a token in a link as admission material only.
- **A sibling route for general TURN.** `POST /api/turn/credentials`, user principal, new scope `turn:relay`, owner from the verified `sub` through `Mjolnir.Deploy.Owner.mint_owner/1`, same refusal order as the room mint, `Cache-Control: no-store`, the same log line shape (sub, owner, label, expiry; never the credential). Operator, sites and capability principals are refused, as they are for the room mint.
- **The edge holds no authority of its own.** `mjolnir-rtc` verifies the bearer against the relay's public key file, then opens its MoQ session to the relay with that same token. The relay enforces the grant as it does today. The edge closes the WebRTC session when the token expires.
- **If a forwarding SFU is ever added,** its token is a different format (LiveKit: a JWT signed with an API secret [R]) and needs a sibling route and a symmetric secret held by the controller and by the SFU.

## Q6. Scale and operations

- **Bandwidth binds before CPU.** Fan-out is N·(N−1)·b in either system: 84 Mbit/s for eight people at 1.5 Mbit/s. [R advise review] One hour of that is about 38 GB of egress. A WebRTC leg adds nothing to the formula; a TURN-relayed leg on this host counts its bytes twice on the wire (in and out of the relay port), though only once across the public interface when the peer is the local edge.
- **CPU, forwarding SFU.** LiveKit's published 16-core figure is 150 publishers and 150 subscribers at 85% CPU. [R] Forwarded streams grow with the square of the room, so half the cores is about 100 by 100, on a host that also runs guests. mediasoup's figure is about 500 forwarded streams per core. [R] These are vendor numbers on other hardware, not measurements here.
- **CPU, MoQ relay.** No figure exists. `mjolnir-rurh.7` owes it. The relay has used 530 CPU-seconds since 2026-11-23 and holds 25 MB [H], which says only that it is idle. Per subscriber byte, QUIC encrypts once per connection just as SRTP does, so the saving is in bookkeeping (no RTP rewriting, no per-subscriber retransmission state), not in cryptography. Expect the same order of magnitude until measured.
- **CPU, the edge.** Each WebRTC session costs a DTLS-SRTP leg, a re-framing step, and a loopback MoQ session. Unmeasured; owed by the scale node below.
- **UDP buffers.** `rmem_max` and `wmem_max` are 212992 bytes. [H] The first MoQ spike already hit that cap inside a guest. [R `mjolnir-pfeq`] Any media service here wants them raised, and that belongs in the forge declarations, not in a deploy script.
- **Ports.** One UDP port for the edge, routed by ICE username fragment [R], so no media range to open. A forwarding SFU can do the same (LiveKit `rtc.udp_port` [R]). TURN needs its relay range. The table in Q1 has all of it, and none of it overlaps the published range or the reserved list.
- **Metering hooks for `mjolnir-rurh.4`.**
  - TURN: owner from the username. eturnal reports per-session byte counts when a session ends [M; spike S1 confirms].
  - Edge: owner from the token root. Per-session bytes in and out, tagged `transport=webrtc`. The ingest cap in `moq-webrtc` [R] is the per-tenant publish limit.
  - Relay: unchanged. An edge session appears at the relay as an ordinary session under the participant's token. `.4` must decide whether a WebRTC participant's bytes are counted at the relay, at the edge, or both, and say so.

## Q7. Exit test and licensing

| Component | License | Exit test |
|---|---|---|
| `mjolnir-turn` (eturnal, unmodified) | Apache-2.0, own process. A metering module of ours loaded into it would be AGPL; Apache-2.0 code may be combined into an AGPL work [M] | **Passes.** TURN stores nothing of the user's. Leaving means naming another ICE server. The credential is a convenience that expires |
| `mjolnir-rtc` (ours, linking `moq-webrtc` and str0m) | AGPL-3.0-or-later host binary; dependencies MIT OR Apache-2.0 [R] | **Passes.** It holds no user key and stores no media. WHIP and WHEP are open specifications, so a client can point at any other server. Its cost is privacy in open rooms, not capture |
| Gateway branch for TURN over TLS | AGPL, existing binary | No user state |
| Browser helper for WHIP, WHEP and the roster | **MIT**, no AGPL dependency, like the other clients [R `docs/philosophy/licensing-and-components.md`] | The client is the user's to keep |
| A forwarding SFU, if added (LiveKit) | Apache-2.0, own process, unmodified | **Passes on keys and data.** Anyone can run the same server. The client protocol is one vendor's, so leaving it means changing a client library; that is a lost convenience, not lost keys |

For an operator, every piece is open source and self-hosted, and each is off by default. A mini-hoster who never enables them is unaffected.

## Recommended architecture

```
                         Internet
                            |
     +----------------------+-----------------------------------+
     |                      |                 |                 |
 TCP 80/443            UDP 443           UDP+TCP 3478       UDP 3479
     |                      |           UDP 61000-65535         |
+----v-----------+   +------v--------+   +----v---------+   +---v-----------+
| mjolnir-       |   | mjolnir-relay |   | mjolnir-turn |   | mjolnir-rtc   |
| gateway        |   | MoQ: QUIC,    |   | eturnal      |   | WHIP/WHEP on  |
|                |   | WebTransport, |   | STUN, TURN   |   | moq-webrtc    |
| sites, API     |   | Iroh          |   |              |   | (str0m)       |
| name           |   |               |   | uid egress   |   |               |
| TURN name:     |   | public keys   |   | rules: only  |   | verifies the  |
|  TLS -> 3478 --+---+---------------+-->| public peers |-->| room token,   |
| rtc name:      |   |               |   | and UDP 3479 |   | public keys   |
|  HTTPS --------+---+---------------+---+--------------+-->| only          |
+----------------+   +------^--------+   +------^-------+   +---+-----------+
                            |                   |               |
                            |   MoQ session with the            |
                            +---participant's own token---------+
                                                |
+-----------------------------------------------+------------------------+
| mjolnir controller (Elixir)                                            |
|  POST /api/relay/rooms/:room/participants/:participant/token           |
|     -> room token (EdDSA, unchanged) + ice_servers (c1 TURN pair)      |
|  POST /api/turn/credentials  (scope turn:relay)  -> g1 TURN pair       |
|  secrets: relay-mint key (asymmetric), turn-mint secret (symmetric)    |
+------------------------------------------------------------------------+

Protected room:  MoQ clients only. moq-e2ee. Host holds no key.  (unchanged)
Open room:       MoQ clients and WebRTC clients. Host can read the media.
```

In a few sentences:

1. **TURN is its own service**, `mjolnir-turn`, running eturnal. The controller mints ephemeral credentials that name the owner. The daemon's filter and a kernel filter on its user both keep it out of guest, sidecar and host addresses. It is useful by itself: a tenant's own WebRTC application can name it as an ICE server.
2. **The MoQ relay becomes the SFU.** A new edge process, `mjolnir-rtc`, embeds the WHIP/WHEP gateway that is already at the pinned moq revision. A WebRTC participant publishes with WHIP and plays each other participant with WHEP, using the room token it would have used over WebTransport. The edge joins the relay as that participant. Fan-out, tenant paths and admission stay where they are.
3. **A room is protected or open.** Protected calls stay MoQ and end-to-end encrypted. Open calls admit WebRTC, and the host can read them.
4. **TURN over TLS on TCP 443 goes through the gateway** by server name, as a later node, so a participant on an HTTPS-only network can join an open call.
5. **A forwarding SFU for protected WebRTC calls is not built now.** It is a named, gated option with LiveKit as the candidate.

Why a sibling process and not code inside `mjolnir-relay`: the relay is live and its spec says only `deploy.sh --relay` changes it; the edge parses untrusted RTP and codec bitstreams, and a fault there should not drop every MoQ call; and as a relay client holding the participant's token, the edge has no authority to misuse. The cost is one loopback QUIC hop per WebRTC session and a second UDP port. Sharing UDP 443 through `Relay::webrtc()` is possible later (spike S8).

## What stays the same

- `mjolnir-relay`: its binary, unit, token profile, key file, UDP 443 listener and spec. The relay still never dials out for a client and still holds no signing key.
- The room mint route, its checks and their order. It gains one response field.
- `add-call-e2ee`: profile, invite format, label context, one secret per call, and "the platform cannot record a protected call".
- The gateway's HTTP behaviour for every existing name. The MoQ relay name still adds no site or route.
- Published UDP ports: range, reserved list, rule shapes.
- Off by default. Each new service has its own flag and its own deploy switch, and enabling anything on production is Duke's.
- The MoQ browser client (`mjolnir-rurh.5`) remains the first-class client. WebRTC is the second door.

## Risks

1. **TURN as a way inside.** The largest. Mitigated twice (daemon filter and uid filter) and tested by trying to reach `10.200.0.1`, loopback, a guest address and the IPv4-mapped forms. Listening services that depend on ufw alone (API, epmd, Forgejo) are a standing reason to keep TCP relaying off.
2. **Open rooms weaken the promise.** The epic says encryption is on by default. An open room is a visible exception. If the page does not label it, users will assume protection they do not have.
3. **Upstream churn.** `moq-webrtc` is 0.3.x and its dependencies break weekly. [R] The pin protects us today; the E2EE work already plans a coordinated pin move to `moq-e2ee-01`, and the edge must move with it.
4. **A gateway is not a conferencing SFU.** One PeerConnection per participant played, no data channels, no per-subscriber layer choice that we have verified. Fine for small rooms; unproven past about eight (spike S6).
5. **Symmetric TURN secret.** A TURN process compromise mints TURN credentials for any owner. It mints no room tokens.
6. **Gateway coupling.** TURN over TLS on 443 lives and dies with the gateway process, unlike everything else in the call path.
7. **eturnal's gaps.** No UDP rate limit per session [R], per-owner quota unverified. The fallback (a Pion daemon) is real work.
8. **Tenant applications in guests.** A relayed packet to a guest's published UDP port starts on the host, and published ports do not cover "hairpin from the host itself". [R CLAUDE.md] So a tenant's SFU in a guest is unreachable through our TURN until an `OUTPUT` rule for the TURN user is added (spike S10). This limits "any WebRTC app" to apps whose peers are outside this host.
9. **Abuse before metering.** General TURN credentials before `mjolnir-rurh.4` have only a host-wide cap.
10. **Scope.** The epic's non-goals forbid this work as written. They need Duke's amendment before any node is created.

## Proposed nodes for `mjolnir-rurh`

No beads are created by this document.

| # | Name | Goal | Depends on | Rigor | Intended acceptance, as a journey |
|---|---|---|---|---|---|
| A | `turn-service` | `mjolnir-turn` runs eturnal on UDP and TCP 3478 with a relay range, off by default, changed only by `deploy.sh --turn`, unable to reach host, sidecar or guest addresses | `mjolnir-rurh.2` (done). Spikes S1, S2 | Architecture, ADR. Human gate: new public service on production, and the TURN hostname | A person on another network opens a standard ICE test page, enters the server and a credential, and sees a relay candidate. The same person asks the relay for `10.200.0.1`, `127.0.0.1` and a guest address and is refused each time, while a packet capture on the host shows nothing sent there. Disabling and redeploying removes the unit and every rule tagged `mjolnir-turn` |
| B | `turn-credentials` | The controller mints owner-bound ephemeral TURN credentials: `ice_servers` in the room mint, and `POST /api/turn/credentials` for scope `turn:relay`. Secret install and rotation script | A | Change (security). Review pair | A signed-in user mints, and two browsers forced to relay-only connect peer to peer through the server. A credential with one character of the owner changed is refused. After expiry the allocation cannot refresh. A user who sends another owner's id in a header gets a credential naming their own |
| C | `turn-tls-443` | A client on a network that allows only TCP 443 reaches TURN through the gateway by server name | A. Spike S3 | Architecture (gateway edge). Human gate | From a network with all UDP and every TCP port but 443 blocked, a browser gathers a relay candidate with `turns:<host>:443`. Every existing site still serves, and the gateway's routing file is byte-identical before and after |
| D | `webrtc-edge` | `mjolnir-rtc` serves WHIP and WHEP for open rooms, admitted by the room token, publishing and playing through the relay | `mjolnir-rurh.3` (done), B. Spikes S4, S5, S7 | Architecture, ADR. Human gate: new public service, and the hostname | One person publishes camera and microphone from OBS or a plain WHIP page with the room token as the bearer. A second person in the MoQ browser client sees and hears them, and the first person plays the second through WHEP. A token for another room is refused. A WHEP request for a protected broadcast fails and plays nothing |
| E | `webrtc-room-client` | The shipped page can join an open room over WebRTC: publish, play every participant, follow the roster, and say plainly that the room is open | D, `mjolnir-rurh.5`. Spike S6 | Change (design shape). MIT client code | Three people on different networks, one on Safari on a phone, one forced through TURN over TLS, one on the MoQ client, are in one open room and each sees and hears the other two. The page shows that the call is not end-to-end encrypted |
| F | `turn-rtc-metering` | Bytes relayed by TURN and by the edge are recorded per owner, and per-owner limits refuse the tenant over them | `mjolnir-rurh.4`, A, D | Change. Could be folded into `.4` as added scope | A tenant over its TURN limit is refused a new allocation while another tenant's call continues. The recorded byte count for a measured transfer is within the stated tolerance |
| G | `webrtc-scale-proof` | A measured ceiling for the edge and for TURN on the production host | D, A, `mjolnir-rurh.7` | Brief | A written table: WebRTC participants per room and concurrent rooms at stated bitrates, CPU per session, the UDP buffer settings needed, and the command that reproduces it |
| H | `protected-webrtc-sfu` (not activated) | A forwarding SFU and a second encryption profile so a WebRTC participant can be in a protected call | Duke's decision 6. Spike S9 | Architecture (cryptography). Human gate. Review pair | With the SFU's own keys available to the tester, a capture at the SFU shows no decodable media, while Safari on iOS, Chromium and Firefox participants holding the invite see and hear each other |

Order: A → B → (C, D in parallel) → E → F, G. H waits.

Also needed, outside the table: amend the epic's non-goals (Duke), add 3478 and the edge's media port to `:published_port_reserved` (part of A and D), and raise the UDP buffer sysctls through forge (part of G or `.7`).

## Spikes

Each is disposable, runs on the laptop (`dorje@…`) and never on production.

| # | Hypothesis | How to test | Gates |
|---|---|---|---|
| S1 `eturnal-fit` | eturnal 1.12.3 accepts REST credentials with our username shape, refuses expired ones on refresh with `strict_expiry`, refuses the listed peers, has no TCP relaying to switch off or lets us switch it off, and exposes owner and bytes per session to a log line or a module | Install it. Mint by hand. Use an ICE test page from another network. Send CreatePermission for `10.200.0.1`, `127.0.0.1`, `::ffff:10.200.0.1`, the laptop's own address and a guest address. Read the session-end log | A |
| S2 `turn-egress-uid` | iptables `OUTPUT` rules matched on the TURN user stop a relay to private and host addresses even when the daemon's own filter is switched off | Empty `blacklist_peers`, allocate, send to each address, and watch the rule counters rise and `tcpdump` on `dummy-mjolnir` and a TAP stay empty. Then confirm a public peer and the edge port still work | A |
| S3 `turn-tls-443-hello` | Chromium, Firefox and Safari put the server name in the ClientHello for `turns:<host>:443?transport=tcp`, and complete a handshake with a server whose ALPN list is `http/1.1` only | Capture each browser's ClientHello against a test listener. Then run the gateway branch on the laptop and gather a relay candidate through it | C |
| S4 `moq-webrtc-embed` | At `4a6f522`, `whip::accept` and `whep::accept` inside a small binary that verifies a room token and opens a relay session with it give working media both ways | A Chromium WHIP page publishes; `iroh-subscribe` and a MoQ watch page play it. An Iroh or MoQ publisher is played by a WHEP page in Chromium, Firefox and Safari. Publish as another label and expect refusal. Let a token expire and expect the WebRTC session to close | D |
| S5 `webrtc-via-turn` | A browser with `iceTransportPolicy: "relay"` and our credential completes ICE with the edge's single UDP port on the same host, over TURN on UDP and on TCP | Run S1's server, S2's rules and S4's binary together. Check that the uid rule admits exactly that port | D |
| S6 `multi-pc-room` | One browser holding one WHIP and seven WHEP connections stays in sync with acceptable CPU; it degrades past about twelve | Eight synthetic participants on the laptop relay. Measure join time, lip sync, browser CPU and edge CPU per session. Repeat at twelve and sixteen | E |
| S7 `protected-refusal` | A WHEP request for a protected broadcast fails with a typed error and delivers nothing playable; a plaintext WHIP publish into a room of protected clients is not rendered by them | Use the `add-call-e2ee` harness relay and its capture method. Check content markers, not decoder exit status, as that design requires | D |
| S8 `port-share` (optional) | The `Relay::webrtc()` feed can drive `moq-webrtc` sessions on UDP 443 | Read upstream past the pin for a constructor that takes the feed. If there is none, estimate the glue | Later optimisation |
| S9 `sfu-label-keys` (only if H) | LiveKit with per-participant keys derived from the invite secret and the label refuses a track the SFU relabels, on Safari iOS, Chromium and Firefox | Two participants, a patched test SFU or a proxy that swaps identities, and the three browsers | H |
| S10 `turn-hairpin-published` (only if wanted) | An `OUTPUT`-chain DNAT for the TURN user lets a relayed packet reach a guest's published UDP port and nothing else | Publish a port to a guest echo service; send through an allocation | Tenant apps in guests |

**Must run before any contract is written:** S1 and S2 (before A), S4 and S7 (before D). S3 before C. S5 and S6 can run while A and D are being contracted but before E.

## Decisions for Duke

Recommendation first in each. Costs are what you give up by choosing that option.

1. **What "SFU" means for the first build.**
   - **Recommended: the MoQ relay with a WHIP/WHEP edge, open rooms only.** One room for both kinds of client; code already at the pin. Cost: the host can read WebRTC legs; small-room shape; no client libraries for phones.
   - LiveKit now, as a separate media plane. Cost: a Go service and a second token secret to operate, WebRTC and MoQ participants cannot share a room, a second encryption design to review if calls are to be protected.
   - Our own forwarding SFU on str0m or mediasoup. Cost: months, plus a client library and congestion logic that we alone maintain.

2. **Are open rooms acceptable?** A room where WebRTC participants join is readable by the host.
   - **Recommended: yes, as a labelled second kind of room. Protected stays the default.** Cost: the product now has an unencrypted mode that someone can pick by accident; the page must make it obvious.
   - No: WebRTC only through a forwarding SFU with frame encryption. Cost: decision 1's second option, and no MoQ and WebRTC in one room, ever.

3. **How wide is TURN?**
   - **Recommended: general-purpose, behind a new scope `turn:relay`, with both filters and a host-wide rate cap from the first day.** This is what "usable by any WebRTC app" asks for. Cost: an authenticated tenant can use relay bandwidth up to the host cap until metering lands.
   - Calls only: credentials come only with a room token and peers are limited to our own edge. Cost: it is not a standard TURN service for anyone else's application; near-zero abuse surface.

4. **Which TURN server.**
   - **Recommended: eturnal.** Cost: no per-session UDP rate limit, per-owner quota unproven, a smaller community than coturn's.
   - coturn 4.19. Cost: a C daemon on the internet with nineteen advisories this year, built from source because the distribution package is old.
   - A small daemon on Pion `turn`. Cost: about 500 lines of Go that we own and must review, in exchange for exact per-owner and per-class control.

5. **TURN over TLS on TCP 443.**
   - **Recommended: yes, through the gateway by server name, as its own node after plain TURN.** Cost: a new branch in the gateway's accept path, and those sessions drop when the gateway restarts.
   - A second public IPv4. Cost: a monthly fee, a relay bind change, and no answer for a one-address mini-hoster. Gains TURN on UDP 443 too.
   - Not now. Cost: participants on HTTPS-only networks cannot join over WebRTC, and they already cannot over MoQ.

6. **Protected calls for WebRTC participants.**
   - **Recommended: not in this round.** Revisit when a protected call must include a phone app or a browser without WebTransport. Cost: until then such a participant can join open rooms only.
   - Now, with LiveKit (node H). Cost: as in decision 1, plus a cryptographic review of the size `add-call-e2ee` needed.

7. **Scope and names.** Amend the epic's non-goals to admit TURN and WebRTC, and choose the two hostnames (for example `turn.worldtree.network` and `rtc.worldtree.network`). These are yours as the relay hostname was. Cost of not amending: no node can be created under the recorded scope.

A smaller point that needs no decision now: enabling moq's WebSocket fallback on the relay (off today) would give MoQ clients a TCP path that keeps end-to-end encryption. It is a different node, and for the "blocked UDP" problem alone it is cheaper than WebRTC. It does nothing for third-party WebRTC applications.

## Sources

Read today, 2026-11-25:

- Repository: `openspec/specs/edge-relay/spec.md`, `openspec/specs/relay-room-auth/spec.md`, `docs/decisions/0016-edge-relay.md`, `docs/decisions/0017-call-e2ee.md`, `openspec/changes/add-call-e2ee/{design.md,tasks.md,reviews/2026-11-23-advise.md}`, `lib/mjolnir/relay/mint.ex`, `lib/mjolnir/published_ports.ex`, `native/mjolnir_relay/{Cargo.toml,src/main.rs}`, `native/mjolnir_gateway/src/{tls.rs,main.rs}`, `docs/philosophy/licensing-and-components.md`, `docs/plans/initiatives/option-c-dual-layer-architecture.md`, `bd show mjolnir-rurh` and children `.4`–`.9`, `mjolnir-pfeq`.
- moq at `4a6f522483168ace392718d68b58a402533c897d` (commit date 2026-11-18), local cargo checkout: `doc/bin/webrtc.md`, `doc/concept/use-case/conferencing.md`, `rs/moq-webrtc/{Cargo.toml,src/lib.rs,src/rate.rs,src/server/mod.rs,src/server/mux.rs}`, `rs/moq-relay/src/relay.rs`, `rs/moq-tokio/src/quic/demux.rs`, `quest/m3/webrtc/README.md`, `quest/m5/relay-handoff-webrtc.md`, `quest/m5/e2ee/README.md`, `drafts/draft-lcurley-moq-e2ee.md`.
- GitHub API: repository metadata, latest releases and tags for coturn/coturn, processone/eturnal, pion/turn, pion/webrtc, webrtc-rs/webrtc, algesten/str0m, livekit/livekit, versatica/mediasoup, meetecho/janus-gateway, jech/galene, elixir-webrtc/ex_webrtc, elixir-webrtc/rel, 8xFF/atm0s-media-server, jitsi/jitsi-videobridge, moq-dev/moq; coturn release notes 4.18.0–4.19.2; coturn security advisories; `pion/turn` `server_config.go`; `livekit/client-sdk-js` `src/e2ee/constants.ts`; commits to `rs/moq-webrtc` since the pin.
- <https://eturnal.net/doc/> and `config/eturnal.yml` in processone/eturnal.
- <https://docs.livekit.io/transport/self-hosting/benchmark.md>, `…/self-hosting/ports-firewall.md`, `…/self-hosting/deployment.md`, `…/encryption.md`, `…/encryption/start.md`, `https://docs.livekit.io/frontends/authentication/tokens.md`.
- <https://mediasoup.org/documentation/v3/scalability/>.
- MDN browser-compat-data (`main`): `api/RTCRtpScriptTransform.json`, `api/RTCRtpScriptTransformer.json`, `api/RTCEncodedVideoFrame.json`, `api/WebTransport.json`, `api/VideoEncoder.json`; a code search for `SFrame` in that repository.
- IETF datatracker API: RFC 8656, RFC 9605, RFC 9725, `draft-ietf-wish-whep-05`, `draft-ietf-avtcore-rtp-sframe-03`, `draft-ietf-moq-secure-objects-01`, `draft-uberti-behave-turn-rest-00`.
- crates.io API: `str0m`, `turn`, `webrtc`, `rtc`, `turn-rs`.
- Web search summaries (not the pages themselves): Enable Security's TURN guidance, MDN's Baseline date for encoded transforms, Mozilla bug 1715625.
- Production host, read-only: `nproc`, `free`, `ss`, `ufw status`, `sysctl`, `ip addr`, `systemctl show mjolnir-relay`.

Not read today and marked [M] in the text: coturn's quota option names, the Ubuntu coturn package version, browser release dates, simulcast and SVC support in LiveKit, mediasoup, Janus and Galene, recording mechanisms of each SFU, Jitsi's dependencies, Apache-2.0 into AGPL compatibility, whether browsers use TCP relay allocations or send `stun.turn`, and eturnal's per-session byte reporting.
