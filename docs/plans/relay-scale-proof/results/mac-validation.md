# Mac validation (2026-11-25)

Host: this Mac. Relay is a child process on `127.0.0.1`. Video 1 Mbit/s
(30 groups/s, every 60th group 8×), audio 80 bytes every 20 ms. 2 rooms × 4
participants, 6 seconds. Socket buffers were not raised.

`net.core.rmem_max` / `wmem_max`: not present (macOS). Recorded
`net.inet.udp.recvspace=786896` and `kern.ipc.maxsockbuf=8388608`.
`/proc/net/udp` and `UdpRcvbufErrors`: not run (no `/proc` on macOS). Deltas
in the RESULT lines are 0 for that reason.

## Baseline

| transport | delivery | p50 | p95 | p99 | joiner first frame | relay CPU avg/max | RSS |
|---|---|---|---|---|---|---|---|
| WebTransport | 1.0000 (11154/11154) | 2 ms | 7 ms | 11 ms | 11 ms | 85% / 134% | 58 MB |
| Iroh | 1.0000 (10750/10750) | 1 ms | 1 ms | 3 ms | 3870 ms | 36% / 73% | 54 MB |

Published groups were 3856 in both of those runs. Session errors 0. Skipped
groups after the first observed frame: 0.

## Control

WebTransport through a UDP proxy that drops 40% of client-to-relay datagrams,
same size:

| | delivery | p95 | joiner first frame | session errors |
|---|---|---|---|---|
| baseline | 1.0000 | 7 ms | 11 ms | 0 |
| 40% loss | 0.4550 (1948/4281, 3215 skipped) | 22 ms | 6165 ms | 0 |

The counters move. A 200 ms delay on that same proxy is a different failure:
all 8 sessions died in the handshake (`control message timeout` / `connect
timed out after 30s`), published 0. That is not a latency percentile; the
setup itself does not survive a 200 ms datagram delay.

`--loss-pct` does not apply to Iroh. Iroh dials the relay endpoint directly.

## Laptop

Not run. `uptime` on `dorje@192.168.0.108` was `load average: 0.84, 1.29, 3.64`
(16 threads), which is not saturated, but three `cloud-hypervisor` guests were
already up for another agent's firewall spikes. No timing run and no build
were started there. Next step, once those guests are gone: `./ramp.sh wt` then
`./ramp.sh iroh` from this directory, binary built on that machine.

## Production

Not run. See `../PRODUCTION-ASK.md`.
