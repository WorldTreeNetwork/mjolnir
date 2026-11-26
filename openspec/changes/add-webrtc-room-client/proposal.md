# add-webrtc-room-client

> **PENDING**

Node `mjolnir-rurh.15` (webrtc-room-client). Rigor: change (design shape). Depends on `mjolnir-rurh.13` for the gateway and on `mjolnir-rurh.14` for a live roster. Duke authorized the contract and the later build on 2026-11-26. There is no page in the tree today. `Mjolnir.Relay.RoomJoin` is the Elixir statement of the comparison, not this client. Product code waits for an independent accept of this contract and for `.13`'s accept. A page that only imports `RoomJoin` is not done.

## Why

A person should join an open room from a MIT page with WHIP and WHEP, see that the room is host-readable, and be refused before the camera turns on when the token is not the room they were invited to. The spike page `add-webrtc-edge/spikes/pages/rtc.html` publishes and plays. It does not compare an invitation root, refuse an old mint, or tear down on expiry.

## What

- **Module, not a finished room.** `join`, `replace`, `renew`, and `teardown` as below. The first shipped surface is one page that calls them. Roster tiles wait on `.14`.
- **Identity before media.** Inputs are the invitation's expected full root, the asked kind (`open` for this page), the mint response (`token`, `root`, `kind`), and an admission result `{ token, root }` produced by verifying that exact token with the relay JWKS (same checks as `assess`: signature, `exp`, root shape). The comparison matches `RoomJoin`: expected root equals admission root equals response root; asked open requires class open and response kind `open`; a protected root or an omitted kind on a non-open root is `open_refused`. No `getUserMedia`, no `RTCPeerConnection`, no WHIP/WHEP POST, and no key import before that returns ok.
- **Gateway.** WHIP and WHEP send the bearer and `X-Mjolnir-Root`. The page treats `403` and `409` as refusal and runs `teardown`. It does not invent a success from a local publish byte count.
- **Notice.** Before media starts, the page shows a host-readable line: the room is open and the host can read it. No lock icon and no "encrypted" copy.
- **Lifetime.** `replace` and `renew` run the same check on the new credential. On failure the previous PeerConnections stay until their own expiry. On success the new sessions are up before the old ones are deleted. `teardown` stops tracks and closes every PeerConnection. A timer calls `teardown` at `exp`.
- **Peers.** Until `.14`, the page plays only broadcast paths the invitation names. It does not present a roster. Announcements may be logged. That is not roster integration.

Capability: `webrtc-room-client` (ADDED). Design: [`design.md`](design.md).

## Impact

- Capabilities: ADDED `webrtc-room-client`.
- ADRs: none.
- Code, after accept and after `.13` can answer: a MIT page and a small TS module under the client tree the relay already ships as MIT. No AGPL import.
- Not in this change: E2EE (`.5` / `.9`), TURN, production hosting of the page.

## User journey & surfaces

The surface is a new page, linked from an invitation that already carries the expected root and a mint token.

- **Working:** asked open, admission root equals the invitation, kind `open`. Notice is visible. Camera starts. One WHIP and one WHEP to a named peer path show the spike's coloured frames.
- **Refused before media:** old mint (no `kind: open`, protected root), mismatched invitation root, expired token, wide root. Camera stays off.
- **Gateway refusal:** the check passed locally and the edge returns `403` or `409`. Tracks stop. Notice can remain.
- **Empty peers:** no named path besides self. Local preview only. No fake participant.
- **Off:** no token in the link. The page explains that and does not call the gateway.

Three browsers on different networks, including Safari on a phone, stay the node's acceptance and are not claimed by the first slice.

## Out of scope

- Full roster UI (`.14`). Do not mark this node done when only self-view works.
- `browser-call-client` (`.5`) and call E2EE.
- Gateway binary (`.13`).
- Safari remote-automation proof until a device is available. Record it as remaining, do not fake it.
