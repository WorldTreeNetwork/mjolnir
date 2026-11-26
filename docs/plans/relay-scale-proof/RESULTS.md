# Relay scale proof (LAN, 2026-11-25)

Host under test: morphie (`192.168.0.164`, wired `eno1`, 12 cores). Generators for the loopback runs were on the same machine, pinned with `taskset` to cores 3–11 while the relay child was pinned to cores 0–2. A second set of WebTransport points ran with the relay unpinned. The cross-machine generator was the Framework laptop (`192.168.0.108`, Wi-Fi). This Mac (`192.168.0.132`, Wi-Fi) was measured only as a UDP path.

No host firewall was enabled, reloaded, or edited. `nftables` and `iptables` were not touched. `net.core.rmem_max` and `net.core.wmem_max` were **4194304** on morphie for the whole run. UDP receive and send buffer error counters did not move (`udp_rcvbuf_delta=0`, `udp_sndbuf_delta=0`, `/proc/net/udp` drops 0), so the buffers were not raised and nothing had to be restored. Morphie's own `beam.smp` (pid 637) and `dummy-mjolnir` were left alone. An `eturnal` process from another agent's TURN cleanup was present at the start and gone by the later runs. Load next to each series is the 1/5/15-minute load at the start of that series; per-step 1-minute load stayed between about 1.4 and 4.7 and included this harness.

`iperf3` is not installed on morphie or the laptop and was not installed. Link ceilings are from `udp-bench.py` (1200-byte datagrams, 3 s). The Mac binary in `harness/target` predates `--connect`, so a Mac generator was not run.

## Link ceilings (label these before reading a split row)

| direction | 20 Mbit/s | 100 Mbit/s | 300 Mbit/s offered |
|---|---|---|---|
| Mac → morphie | 5824/5824 | 28600/28600 | 69599/87472 (80%), **223 Mbit/s received** |
| morphie → Mac | 6240/6240 | 31200/31200 | 93720/93720 (300 Mbit/s) |
| laptop → morphie | 6228/6240 (99.8%) | 31200/31200 | 93720/93720 |
| morphie → laptop | 6203/6240 (99.4%) | 30459/31200 (97.6%) | 92871/93720 (99.1%, 297 Mbit/s) |

Fanout at 1 Mbit/s video is about `N * P * (P-1) * 1.03` Mbit/s toward the subscribers, plus ~32 kbit/s audio. Two rooms of 16 is ~495 Mbit/s of fanout. Two rooms of 8 is ~115 Mbit/s. The Mac→morphie path is the weak direction (loss starts between 100 and 300 Mbit/s). The laptop path held 300 Mbit/s both ways.

## What one relay held

Stop rule: delivery below 0.99 or p95 above 300 ms. Every passing row below has p95 under 10 ms except where a number is written. Session errors were 0 on the passing pinned rows. RSS stayed under 160 MB.

WebTransport and Iroh, relay pinned to 3 cores. Video is 30 groups/s with a keyframe every 60 groups. Audio is 50 groups/s of 80 bytes. A row is the worst of the two series (raise rooms at 4 participants, then raise participants at 2 rooms).

| case | held | first miss | relay CPU at the miss | what failed |
|---|---|---|---|---|
| WT 1 Mbit/s, 3-core pin | 8 rooms × 4, and 2 × 8 (delivery 1.000, p95 4–6 ms). Relay CPU 121% at 8×4, 99% at 2×8 | 2 × 16: delivery **0.576**, p95 100 ms, 84644 skipped, 0 session errors | avg **262%** / max 285%, **6 threads** | relay cores (the pin is 300%) |
| WT 300 kbit/s, 3-core pin | same shape, 8×4 delivery 1.000 | 2 × 16: delivery **0.859**, p95 53 ms, 31695 skipped | avg **275%** / max 286%, 6 threads | same pin, not the bitrate |
| WT audio only, 3-core pin | 2 × 16 delivery **0.9995**, p95 10 ms, relay 253% | 2 × 32: delivery **0.336**, p95 217 ms, 350821 skipped, 668 late | avg **270%** / max 286%, 6 threads | pin again |
| Iroh 1 Mbit/s, 3-core pin | 8×4 delivery 1.000, p95 3 ms, relay only 44% | 2 × 16: delivery **0.806**, p95 61 ms, 34968 skipped | avg **57%** / max 144%, 6 threads | not relay CPU (see below) |
| Iroh 300 kbit/s, 3-core pin | 2 × 8 delivery 1.000 | 2 × 16: delivery **0.891**, p95 49 ms | avg **60%** / max 147% | same, relay idle relative to WT |
| Iroh audio only, 3-core pin | 2 × 16 delivery **0.9995**, p95 12 ms, relay 59% | 2 × 32: delivery **0.413**, p95 171 ms, p99 358 ms, 81974 skipped, 1207 late, 0 session errors | avg **44%** / max 120% | generator / Iroh path, not the pin |

Unpinned WebTransport spot checks (12 cores shared, load ~3.3 then ~5.1):

| case | delivery | p95 | relay CPU | threads | session errors |
|---|---|---|---|---|---|
| WT 1 Mbit/s, 2 × 16 | **0.9895** | 24 ms | avg **464%** / max 485% | **15** | 1 (`subscribe: not found`) |
| WT 1 Mbit/s, 2 × 16, relay pinned to 8 cores, generator to 4 | **0.9924** | 21 ms | avg 435% / max 455% | 11 | 17 subscribe misses |
| WT audio, 2 × 32 | **0.9418** | 38 ms | avg **468%** / max 489% | 15 | 598 subscribe misses |

The 3-core pin is what made 1 Mbit/s WebTransport fall over at 16 participants. Given the whole machine, that case uses about **five cores** and sits on the 99% line. Audio at 32 participants still misses 99% with the relay at the same ~4.7 cores, so a sixth core is not what that row is waiting on. UDP buffer counters stayed 0 in every one of these runs.

Laptop generator, relay on morphie, WebTransport, 1 Mbit/s (laptop 1-minute load 0.8–0.9; morphie 1-minute load ~3.5–4.3 from the earlier loopback). Relay CPU in the RESULT is 0 because the relay is not a child of the generator. A lifetime `ps %cpu` on the long-lived relay climbed while these ran and is not an instantaneous core count.

| participants (2 rooms) | delivery | p95 | generator CPU avg/max | vs loopback |
|---|---|---|---|---|
| 4 | 1.0000 | 6 ms | 36% / 40% | matches pinned loopback (p95 2 ms) |
| 8 | 0.9984 | 9 ms | 104% / 123% | matches (loopback p95 6 ms, delivery 1.000) |
| 16 | **0.9901** | 23 ms | 333% / 365% | matches the **unpinned** loopback knee (0.9895, p95 24 ms) |

These three rows are relay-limited, not link-limited. Two rooms of 16 is the same 99% line the unpinned loopback hit, and the laptop path had just carried 300 Mbit/s of plain UDP in both directions. A size the loopback failed only because of the 3-core pin succeeded across Wi-Fi once the relay could use more cores.

Iroh from the laptop did not connect: `iroh link not connected` within 10 s, delivery 0. That attempt was also before the token clock leeway below, so it is **not** a bitrate result. The relay's Iroh sockets were `0.0.0.0` and an IPv6 wildcard (`READY` printed them). The client dials `RelayConfig::iroh(endpoint_id)` and this iroh 1.4.1 build has no direct-address API, so a split Iroh run can leave the LAN via discovery. Loopback Iroh does connect, in the times below.

One morphie-local check of the same `--connect 192.168.0.164:24440` path (1×2, audio) delivered 1.000 with p95 2 ms, which is how the laptop failures before the bind fix and the clock leeway were separated from the relay.

## The two Mac oddities

**About one core for 8 participants on WebTransport.** That CPU was the relay child. The loss proxy was off, and the generator is the parent process. On morphie the same 2 rooms × 4 participants is only ~35% of one core (the Mac's 85% average / 134% peak was the slower core doing the same TLS and fanout). It tracks subscriptions, not headcount. Edges in a room are `P * (P-1)` per track. At 1 Mbit/s WebTransport, pinned:

| shape | participant-edges | relay CPU avg |
|---|---|---|
| 2 × 2 | 4 | 12% |
| 2 × 4 | 24 | 35% |
| 8 × 4 | 96 | 122% |
| 2 × 8 | 56 | 99% |
| 2 × 16 | 240 | 262% (and the 3-core cap) |

Eight rooms of 4 and two rooms of 16 are both 32 participants. The CPU is 122% versus 262%. Same people, four times the edges, about twice the CPU, until the pin stops it. Unpinned, 2×16 spreads across ~5 cores and 15 threads. It is not one hot thread once the process is allowed more than three cores. Under the 3-core pin the thread count stayed at 6.

**About 3.9 s to first frame for an Iroh joiner, against ~11 ms on WebTransport.** The new phases split that wait. Across every pinned Iroh row from 1×4 through 2×16, connect stayed **~820 ms** and "subscribes finished" stayed **2.4–4.5 s**. The first media sample was a few milliseconds after that. WebTransport at the same sizes was connect 2–8 ms, first frame 5–9 ms (16 participants rose to ~150 ms under the pin, still not seconds). Steady-state Iroh p95 stayed 1–3 ms, so the 8 s request retry is not what fired and the relay path after setup is fast. The cost is fixed Iroh setup (endpoint connect, then waiting until the other announces are routable), and it does not grow with rooms until the 2×32 audio miss, where connect itself jumped to 2.8 s and first frame to 6.5 s. Direct LAN addressing was not added; iroh 1.4.1's endpoint builder has no `add_node_addr`.

## How it fails, and what would raise it

One relay on this machine holds **8 concurrent rooms of 4 participants**, and **2 rooms of 8**, at 1 Mbit/s video and at 300 kbit/s, on both WebTransport and Iroh, with essentially full delivery and p95 under 10 ms. Audio-only (about 32 kbit/s, no video track) holds **2 rooms of 16**. The rooms series never missed through 8 rooms; the participants series is what hits the line. Past that, WebTransport at 1 Mbit/s holds **2 rooms of 16** only when the relay can use about five cores (delivery 0.99, p95 ~24 ms). The 3-core pin used for the clean CPU split cannot. It does not fall over by blowing p95 through 300 ms or by filling the UDP socket buffers. It skips groups, and at 32 participants WebTransport also starts returning `subscribe: not found` while the process stays up. Iroh misses 2×16 with the relay still under two cores, so that miss is on the session/generator side, not the same core cap. Nothing here was limited by the 4 MiB socket buffers.

To raise the WebTransport number, give the relay process more than three cores (it used five when offered twelve) and keep the room size down, because each extra participant adds a subscription to everyone else. Bigger UDP buffers would not have moved this knee. A laptop on this Wi-Fi can drive the 2×16 case; the Mac's path toward morphie is the one that already drops UDP between 100 and 300 Mbit/s, and that generator was not run.

## Reproduce

```bash
# morphie, after copying the tree to /var/tmp/relay-scale-src
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --release --manifest-path docs/plans/relay-scale-proof/harness/Cargo.toml \
  --target-dir /var/tmp/relay-scale-target
# loopback, relay on cores 0-2, generator on 3-11
OUT=/tmp/out.txt RELAY_CORES=0-2 taskset -c 3-11 \
  sh docs/plans/relay-scale-proof/ramp-one.sh \
  /var/tmp/relay-scale-target/release/relay-scale wt 1000 loopback-wt-1000
# split: relay-scale keygen, then serve --bind 0.0.0.0:24440 --keys verify.json
# generator: relay-scale run --connect 192.168.0.164:24440 --mint-key mint.json --iroh <READY id>
```

Tokens are backdated 180 s because the laptop clock was about two minutes ahead of morphie and a future `iat` comes back as `unauthorized`. The WebTransport client binds `127.0.0.1` for a loopback relay and `0.0.0.0` otherwise; a loopback bind cannot reach another machine. Scratch on morphie was `/var/tmp/relay-scale-src`, `/var/tmp/relay-scale-target`, and `/var/tmp/relay-scale-out`, removed after this writeup.
