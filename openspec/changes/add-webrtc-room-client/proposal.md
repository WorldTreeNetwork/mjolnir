# add-webrtc-room-client

> **PENDING**

Node `mjolnir-rurh.15`. The whole node stays blocked by `.13` and `.14`. Duke authorized a named-peer slice on 2026-11-26. That slice may run after a fresh accept of this contract and a green local `.13` slice. It does not implement a roster and it does not close the node. Product code waits for those accepts. No deploy.

## Why

Three equal strings are not an admission. The previous `jwks` argument let the caller supply the key. `Mint.issue` returns no verify set. The filesystem key is not a browser endpoint. `RoomJoin.check/4` is the comparison order, not a verifier and not this page.

## What

- **Trust.** The page is configured with one gateway origin. It never takes that origin from the invitation, the query string, or `relay_host`. `POST /admit` on that origin is the only admission producer. The module compares the invitation's expected root and the mint `kind` locally, in `RoomJoin` order, against the root `/admit` returns for this exact token. A caller `{ok:true}` is ignored.
- **Before media.** `/admit` may run first. `getUserMedia`, `RTCPeerConnection`, content-key import, WHIP, and WHEP wait until it succeeds. Public verification material is not a content key; this slice does not import a JWKS at all.
- **Invitation.** `{ expectedRoot, asked, selfPath, peerPaths, retryMs }`. Paths are relative broadcast strings. Reject absolute URLs, schemes, backslashes, and dot segments before any request. Peer count at most 7. `retryMs` at least 1000. The page builds URLs only on the configured origin.
- **Candidate.** One attempt owns its abort controller, camera tracks, PeerConnections, session ids, and timer generation. Failure drops only that candidate. An incumbent stays until its own `exp` or an explicit leave. Explicit leave drops both. A late callback from generation N cannot attach media or DELETE generation N+1.
- **Commit.** WHIP `201` plus `setRemoteDescription` success commits the candidate even if a named peer is `409 not_started`. Those peers stay empty and retry with backoff until `exp` or a non-retryable error. `codec_unavailable` fails that peer tile and does not retry. `403` on WHIP fails the candidate. `403` on a peer WHEP fails that tile. A `201` alone is not "media flowing"; ICE `connected` or a 10 s timeout decides. Timeout fails that PC only.
- **Renew.** Consumes a mint response the caller already holds. This page cannot mint. Checks run again. New WHIP must reach the commit point before old session ids are DELETEd. If the new WHIP fails, new resources drop and old ones stay. Old timers do not close new PeerConnections. Tracks the successor still uses are not stopped.
- **Remote cleanup.** `teardown` DELETEs each owned id with its admitting bearer, then closes PCs and stops tracks this generation owns. DELETE is best-effort with a 2 s bound. Gateway `exp` is the backstop.
- **Named-peer end.** If the playing PC ends before `exp`, the page retries that path. It does not claim the relay will follow a replaced publisher. Full handover is not this slice.
- **Notice.** "This room is open. The host can read the media." Visible before the camera prompt. No lock, no E2EE wording.

## Impact

- Capabilities: ADDED `webrtc-room-client`.
- Code after the gates: MIT page and module. No AGPL import.
- Spike `rtc.js` may be lifted for the POST and the frame sampler only. Its query-string edge URL is not copied.

## User journey & surfaces

The page is opened from an invitation that carries the expected root and a token. The gateway origin is the build's configuration.

- **Working:** `/admit` ok, notice visible, camera, one WHIP, one named WHEP, colours and tone match.
- **Refused before camera:** bad signature at the gateway, wrong root, old mint (`unexpected_root` when the expected root is open and the admitted root is protected), `open_refused` when the expected root is protected and the ask is open, `kind_mismatch` when the root is open and `kind` is omitted.
- **Partial renew:** new WHIP fails, old call remains, new tracks are gone.
- **Empty peer:** `not_started` shows an empty tile and retries. No invented participant.
- **Off:** no token. No gateway call.

Safari on a phone, three networks, and eight PeerConnections stay open. They are not this slice.

## Out of scope

- Roster SSE (`.14`).
- Automatic minting, TURN, E2EE (`.5`).
- Building the gateway (`.13`).
- Treating the Elixir module as the page.
