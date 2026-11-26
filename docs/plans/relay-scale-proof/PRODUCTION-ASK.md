# ASK — production relay scale run

Do not run this until the owner says yes. The host is `45.76.77.97`
(8 cores, live tenant VMs, live `mjolnir-relay` on UDP 443 as
`media-relay.worldtree.network`). This turn did not load it.

## What would run

A second relay, not the live one. Same binary as production (`mjolnir-relay`),
loopback or a high UDP port that is not 443, with a throwaway verify key.
Clients are `relay-scale` on the Framework laptop (`dorje@192.168.0.108`),
never on the production host, so guest CPU is not the load generator.

```bash
# on the server, in /tmp/relay-scale, throwaway key and TLS, port 24433
MJOLNIR_RELAY_HOST=scale-proof.invalid \
MJOLNIR_RELAY_BIND=127.0.0.1:24433 \
MJOLNIR_RELAY_TLS_DIR=/tmp/relay-scale/tls \
MJOLNIR_RELAY_KEYS=/tmp/relay-scale/verify.json \
MJOLNIR_RELAY_KEYS_ACTIVE=/tmp/relay-scale/keys.active \
MJOLNIR_RELAY_STATE_DIR=/tmp/relay-scale/state \
  /usr/local/bin/mjolnir-relay
```

The laptop then runs `ramp.sh` against an SSH tunnel (`-L 24433:127.0.0.1:24433`)
for WebTransport, and against the throwaway relay's Iroh endpoint id for Iroh.
Video 1 Mbit/s, audio 32 kbit/s, 8 s per step. Same knee rule: delivery < 99%
or p95 > 300 ms.

A tunnel hides the server's real UDP path. After the tunnel knee is known,
one confirmation step (the knee size, once, 8 s) would bind the throwaway
relay on a public high port only if the owner names that port. It must not be
443, 20000-20099, or a published-port reserved number.

## How long, and how much

Ramp as written is at most 10 steps × 8 s of media, plus setup. Budget 15
minutes of wall clock including aborts.

Bandwidth at the knee we will not cross on purpose. Upper bound if a step
reaches 2 rooms × 50 participants before the knee: each participant sends
about 1.03 Mbit/s and receives 49 × 1.03 Mbit/s. That is about 100 Mbit/s up
and 5 Gbit/s down at the generator, and the relay forwards on the order of
2 × 50 × 49 × 1.03 Mbit/s ≈ 5 Gbit/s. That step must not be the first
production step. Start at 1×4 and stop at the first bad step. Expected first
steps (2×4, about 24 Mbit/s of forwarded media) are small next to a host that
already serves tenants.

CPU: the throwaway relay is one process. Abort if its CPU stays above 600%
for 2 s (leaves 2 cores for guests and the live relay) or if load average
goes above 6.

## Abort

Kill the throwaway relay and the laptop `relay-scale` if any of these happen:

- delivery under 99% or p95 over 300 ms (that step is the result, then stop)
- relay RSS over 2 GiB
- `UdpRcvbufErrors` climbing during a step
- any guest `mj` health failure, or the live relay's existing sessions logging
  new errors (`journalctl -u mjolnir-relay` since the step started)
- a tenant VM's CPU wait visible in `journalctl -u mjolnir` as a boot or
  exec timeout during the step

Restore any `sysctl -w net.core.rmem_max` / `wmem_max` to the recorded old
value before exiting. Do not enable `MJOLNIR_RELAY` changes, do not restart
`mjolnir` or `mjolnir-relay`, do not touch UFW or iptables.

## What stays untouched

The live relay on 443, its key in `/etc/mjolnir-relay/relay-keys.json`, its
mint key, and every guest. The proof relay uses `/tmp/relay-scale` only and
is killed at the end. No firewall change. No persistent sysctl.
