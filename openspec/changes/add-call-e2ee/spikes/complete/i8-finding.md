---
spike_id: i8-authenticated-group-order
run_at: 2026-11-24
verdict: go
version-pinned: moq@4a6f522483168ace392718d68b58a402533c897d
---

# I8 — authenticated media delivery and resubscription

Method: **userspace virtual-delivery shaper in the disposable harness**, not dummynet/pf and not physical QUIC packet loss. Seeded group delivery applies uniform 0–50 ms jitter; 2% of groups receive an extra 80 ms retransmission delay, modeling reliable delivery after loss. Virtual timestamps avoid scheduler-load bias. Real 20 ms Opus packets from a private ffmpeg 440 Hz tone are sealed/opened through pinned MoQ/E2EE groups; plaintext equality is asserted before the policy mark advances. This measures admission counts, not audible quality or a network latency guarantee. Source [i8-shaper.ts](i8-shaper.ts), raw [log](logs/i8-shaper.log), [reproducer](i8-repro.sh).

| Window | Authenticated audio frames | Delivered | Refused | Reoffers refused | Maximum remembered starts |
|---|---:|---:|---:|---:|---:|
| 0 ms | 9000 | 7194 | 1806 | 9000 | 1 |
| 60 ms | 9000 | 8895 | 105 | 9000 | 4 |
| 120 ms | 9000 | 9000 | 0 | 9000 | 7 |

Three independent seeds (17/42/2026), 3000 groups each, 179 simulated losses total (1.989%). Reoffers include both duplicates and already-too-old groups; none is delivered again. Choose **120 ms media window**, remembering authenticated starts/frame indices, dropping a group strictly more than 120 ms behind the newest authenticated group start. Already opened frame indices never reopen. Keep zero window for catalog and manifest. Derive group-start units from authenticated manifest timescale at integration, not relay TRACK_INFO. This is the measured choice for this loss/retransmission model; C2 needs actual playback/loss validation on the integrated bridge.

Resubscription assertions: video and a single long-lived catalog group each contain five frames. After indices 0–1, replace the raw subscription/cursor and resume at index 2, using one retained key/budget and mark/mirror. The same mirror ends with all five unique frames, saved index 4, and refuses replay indices 0–1. These use pinned internal wrapper hooks, as upstream's resume test does; they do not pretend the public decrypted Frame already exposes its authenticated transport index. **Integration gap:** js/e2ee/src/group.ts Frame exposes timestamp/plaintext only. C2 needs an index-preserving adapter/upstream hook before wiring the policy; do not infer resumed indices from an unauthenticated timestamp or renumber at zero. No product code or new cryptography is used by this spike.
