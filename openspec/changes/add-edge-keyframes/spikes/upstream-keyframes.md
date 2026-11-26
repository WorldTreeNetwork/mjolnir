# Spike `upstream-keyframes`

Claim under test: upstream moq `main` already asks a WHIP publisher for keyframes on ingest, forwards a WHEP viewer's PLI/FIR, or offers an option for either, or an issue or PR for it is open.

**Verdict: REFUTED.** Read 2026-11-26 02:50 UTC (2026-11-25 US time). Upstream `main` at `9901b7112b443e04c5f7ef811008c5fc4f4a75d0` (committed 2026-11-26T02:29:03Z, "ci(rs): the gate builds moq-net's fuzz feature on its own (#9665)"). `moq-webrtc` is still 0.3.12 there. Raw output: [`evidence/upstream-keyframes.txt`](evidence/upstream-keyframes.txt). Method: shallow clone into a scratch directory outside this repo, `grep` over `rs/moq-webrtc/src` and `rs/moq-net/src`, and `gh search issues` / `gh pr list` on `moq-dev/moq`. Nothing was opened or pushed upstream.

## What upstream `main` has

| Question | `main` 9901b71 | Pin 4a6f522 |
|---|---|---|
| WHIP ingest asks for a keyframe | Only while a video line waits for its first keyframe, and for a deferred timeline step (`session.rs:325-345`). Never on a period, a join, or loss | Same (`session.rs:296-313`) |
| Egress forwards a viewer's PLI/FIR | No. "For v1 we just log and rely on the next natural keyframe from the MoQ source" (`session.rs:367-371`) | Same (`session.rs:337-341`) |
| An option for either | No. `moq_mux::Ingest` has `max_age`, `bandwidth`, `linger`, `rate`. `whip::Request` has `publisher`, `broadcast`, `offer`, `ingest` | Same |
| `moq-webrtc` uses moq-net refresh or demand | No (`grep` finds only a test's `low.demand()`) | No |
| Open issue or PR | None. No open PR mentions WebRTC keyframes; the three open `webrtc` hits are a timeline change, a rind bump and audio groups | — |

## What upstream has nearby, and why it matters

- **#2284** "moq-net: keyframe request (PLI equivalent) for fast tune-in", closed 2026-10-08. Closed through **#3256** (merged 2026-08-31), which replaced the request with a GOP-overhead quest. Its reasoning: a joiner already gets the newest group from its keyframe, so a 2 s GOP is enough and the joiner pays only catch-up. That premise holds for an encoder with a GOP schedule. A browser WHIP publisher has none: Chromium sends a keyframe only when asked or when it changes resolution (`add-webrtc-edge/spikes/finding.md`, claim 1). Its group grows without bound, and catch-up grows with it (erin, uncapped VP8: 394 frames, about 7 s of backlog). This is the argument the upstream PR has to make.
- **#6270** (closed 2026-10-22, declined). A relay operator asked for an out-of-band keyframe request. The maintainer pointed at `track::Info::refresh`: a joiner at the live edge moves `Demand::wanted` past the newest group, and the publisher opens a fresh one (moq-video forces a keyframe). So the upstreamable ingest half is "WHIP ingest answers moq-net's refresh demand with a PLI", not a new signal.
- **`main` has more refresh machinery than the pin.** `track::Info::refresh` is now a `Refresh { ratio, interval }` struct; `interval` is a per-hop floor between requests. `Demand::poll_refresh` is the publisher's wait. `Subscriber::refresh()` is public: a reader asks for a newer group, coalesced and forwarded upstream. At the pin, `refresh` is `Option<u32>`, there is no interval, and the reader-side `Subscriber::join` is `pub(crate)`. moq-video's capture path on `main` uses `with_refresh(Refresh::default().with_ratio(..))`.
- **Refresh does not cross a lite-06 hop.** `Version::has_refresh` is false for lite-01 to lite-06 on both `main` and the pin. lite-07 is advertised as `moq-lite-07-wip` and "only when explicitly requested; the default version sets leave it out". The spike sessions negotiated `moq-lite-06`. So on today's default wire, a join at the relay, or a WHEP egress reading through the relay, sends nothing back to the edge.

## Consequence for the contract

The shape stands: a carried patch at the pin, and an upstream PR. Two parts change shape:

1. The upstream PR is not a port of the carried patch. On `main` the ingest half uses `Refresh { ratio, interval }` and `Demand::poll_refresh`, and the egress half turns a viewer's PLI/FIR into `Subscriber::refresh()`. At the pin those do not exist, so the carried patch uses `Demand::wanted` and an explicit handle. See design D3 and D7.
2. Periodic requests are required, not optional. On lite-06, refresh never reaches the edge from relay readers, so the period is the only thing that bounds a MoQ joiner's backlog.

Spike line for the node: `upstream-keyframes` — refuted (upstream `main` 9901b71 has none of it; no open issue or PR). Contract shape stands, with the two changes above.
