# Relay scale proof

Measured ceiling for one Mjolnir MoQ relay: rooms × participants at a stated
video bitrate, plus the UDP buffer settings in effect. This is a brief, not
an OpenSpec change. Production (`45.76.77.97`) is not loaded from here.

## Why this is not `irl run`

iroh-live `747b1bd` `irl run` reads one TOML session: one endpoint, `[[send]]`
capture blocks and `[[recv]]` tickets (`iroh-live-cli/src/run.rs`). It does
not mint `Mjolnir.Relay.Mint` room tokens (`t/<owner>/<room>`, publish
`<participant>/**`, subscribe `**`) and it does not open N rooms. The harness
is `harness/` (`relay-scale`), built on the same client calls as
`native/mjolnir_relay/examples/wt-session.rs` and `iroh-publish.rs`.

## Build

```bash
cargo build --release --manifest-path docs/plans/relay-scale-proof/harness/Cargo.toml
```

Binary: `docs/plans/relay-scale-proof/harness/target/release/relay-scale`.
`target/` is gitignored. Do not commit it.

## One run

```bash
BIN=docs/plans/relay-scale-proof/harness/target/release/relay-scale
"$BIN" run --transport wt  --rooms 2 --participants 4 --seconds 6 --video-kbps 1000
"$BIN" run --transport iroh --rooms 2 --participants 4 --seconds 6 --video-kbps 1000
```

Each participant publishes audio (80-byte groups, 20 ms, about 32 kbit/s) and
video (30 groups/s, 1 Mbit/s average, every 60th group an 8× keyframe) and
subscribes to every other participant in its room. Tokens are signed with a
throwaway EdDSA key the child relay trusts. The relay is a child process.

WebTransport controls (they do not apply to Iroh, which dials the relay
endpoint directly):

- `--loss-pct 30` drops that fraction of client-to-relay UDP datagrams.
- `--delay-ms 200` delays both directions of that proxy.
- `--burn-threads 4` spins threads inside the relay process.

`delivery` is delivered frames / the sequence span each subscriber observed
after its first frame. Groups published before that subscriber attached are
not loss. Iroh publishes the absolute path `t/<owner>/<room>/pN`. WebTransport
publishes `pN` because the session is already rooted there. A relay link must
consume; `with_consume(false)` keeps routes out of the subscriber's table.
A line starts with `RESULT`. Stop a ramp when delivery < 0.99 or p95 > 300 ms.

## Ramp

`./ramp.sh wt` then `./ramp.sh iroh`. Fixes participants at 4 and raises
rooms 1, 2, 4, 8, then fixes rooms at 2 and raises participants
2, 4, 8, 16, 32, 50. Eight seconds per step. Writes `results/ramp-<transport>.txt`.

Linux socket buffers, only for a run you are watching, and only if you put
the old value back:

```bash
old=$(sysctl -n net.core.rmem_max)
sudo sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216
# rerun the failing step
sudo sysctl -w net.core.rmem_max=$old net.core.wmem_max=<old wmem>
```

`/proc/net/udp` and `UdpRcvbufErrors` exist on Linux. On macOS those counters
stay 0 and the RESULT records `net.inet.udp.recvspace` / `kern.ipc.maxsockbuf`
instead. That is unread, not a measured drop count.

## Do not

Do not point this at `45.76.77.97` until the owner accepts
`PRODUCTION-ASK.md`. Do not change a host firewall. Do not leave the relay
child running; the parent kills it on exit.
