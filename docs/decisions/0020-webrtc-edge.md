# ADR 0020 — WebRTC edge admission

**Status:** Draft, for independent review with `add-webrtc-edge`. Not an implementation accept. Not a production deploy.
**Change:** [`add-webrtc-edge`](../../openspec/changes/add-webrtc-edge/proposal.md)
**Argument:** [`design.md`](../../openspec/changes/add-webrtc-edge/design.md)

## Decision

`mjolnir-rtc` is a separate unit, off until a deploy flag that this ADR does not authorize. It publishes and plays only through the MoQ relay.

One relay connection is keyed by the exact bearer bytes. Legs that present that same token share it. A different token, including a renewal, gets its own connection. Sharing is never across roots or grants. Each WHIP, WHEP, and admission preflight runs `assess` again on the current key snapshot. An existing connection does not authorize a new operation.

The browser does not hold the verify set. Before camera or SDP it calls `POST /admit` on a configured gateway origin. That route runs the same admission and dials no relay. WHIP and WHEP repeat admission. The invitation root is untrusted input; equality with the assessed root narrows authority and never creates it.

WebRTC legs are host-readable. The page says so. There is no E2EE on this path.

## Consequences

- N full-mesh participants still have N² WebRTC legs. Relay connections drop toward N while each person uses one token.
- A failed candidate drops only its own `moq_webrtc` response and its hold on the connection. The last hold closes the connection. DELETE with the admitting bearer drops one session id.
- `moq_webrtc::server::Response` has no public DTLS close method. Acceptance is that the runner is dropped, so no further media is forwarded. Browser notification of that close is the spike's observed 6–7 s, not a required `close_notify`.
- Routine key rotation keeps admitted sessions until `exp`. An invalid reload fails closed for new admissions. Emergency drain closes the relay connection and therefore every leg on it.
- Wide `t/<owner>` tokens are test fixtures. `Mint.issue` does not create them.
- Per-owner byte caps stay on `.4`. Roster stays on `.14`.
