# add-edge-keyframes

> **ACTIVE BUILD**

Node `mjolnir-rurh.12`. Rigor: change. Blocks `.13` until this node's ingest feasibility and measurements are accepted. Owner decision 2026-11-25: carry a patch, do not move the pin; upstream push stays with Duke. Owner decision 2026-11-26: no viewer PLI forwarding and no in-process WHEP. Independent accept of `6abb5065` is `reviews/2026-11-26-advise-2.md`. Activation uses Duke's already recorded build grant. No new permission. No deploy. No viewer bypass.

The superseded viewer-path prose is `notes/withdrawn-viewer-path-design.md`. Reviews are unchanged.

## Why

A WHIP publisher sends a keyframe when asked or when resolution changes. At pin `4a6f522` the ingest asks only until the first keyframe and on a timeline step. A late reader chews a long group. A viewer's PLI is logged and dropped. Upstream `main` (`9901b71`) does not add a period or an option. This change adds the ingest cadence only.

## What

- **Active policy.** Enabled: period 2 s, refresh ratio 4, loss PLI, one 1 s floor on every PLI the ingest actually sends, including the pinned startup and step paths. Disabled: pinned behaviour. No viewer cause.
- **Not in the patch.** `Response::keyframes`, `Requester`, `whep::Request::source`, a pairing table, an in-process WHEP origin.
- **Carry.** Vendor `moq-webrtc` only. Relay lock unchanged.
- **Upstream.** Local ingest-only port and a PR draft that includes the measured cost. No WHEP refresh in this port. Drop the vendor when the pin has that ingest behaviour.

Active design: [`design.md`](design.md).

## Impact

- Capabilities: ADDED `webrtc-edge` (cooldown, period and loss, join ratio, relay-only WHEP negative, pin unchanged). The gateway's own requirements are `add-webrtc-edge`.
- ADRs: none here.
- Code after accept: `native/vendor/moq-webrtc/`, the check script, NOTICE, harness, `upstream/`.
- Not changed: relay manifest and lock, production, any remote git push.

## User journey & surfaces

No new UI because `.13` and `.15` own the pages. Harness only.

- **Late MoQ reader:** groups are about one period when the encoder answers. Decode starts without a viewer PLI.
- **Late WHEP viewer:** plays through the relay. Their PLI does not reach the WHIP encoder. Recovery waits for the ingest period. The 1.2 s figure is an observation, not a pass.
- **Publisher loss:** the ingest asks. That path is the loss-cause measurement.
- **Off:** policy disabled. Pinned PLIs only.

## Out of scope

- Viewer-driven refresh. Separate follow-up. Not a drop condition.
- In-process playback, pairing, edge-local metering of a bypassed viewer.
- The `mjolnir-rtc` unit (`.13`).
- Production deploy.
