# Corrected page against the accepted gateway

Evidence only. Page source and gateway binaries were not modified. The fixture run in `../2026-11-27-code-ui-fixes/` is a different server: its hung DELETE and 44 ms local clear are not this result.

Page git `72ec6110`. Gateway binaries are the accepted `4bd94d1d` build, sha256 `57a21527cd79204d23354337b957ec7efc1240d6f2ba0bf4b4e71f9b9900e343` (`mjolnir-edge`, BuildID `2fd7314be7dce560ba6e179ceb0bc90270f615b9`) and `9c24f67c28fc612644d8ccf90ed833895b205089cddb1e30800d8c89ee72e344` (`mjolnir-relay`, BuildID `fe6c0a81c428142505e7c556db350f6c96fcc970`). Chromium 156.0.8078.79. Node v26.13.1. Mint was `Mjolnir.Relay.Mint.issue` for alice, alice2, bob (ttl 600) and alice (ttl 2). `mint.txt` has root length 54 and `exp` only.

Served hashes: `page/boot.js` `7065d95e…e3db`, `page/room.html` `d5a2a91f…f415`, `page/room.css` `67a3093e…3cc7`, `src/room.js` `32b25c88…c078`. `page/config.js` is the harness origin `http://127.0.0.1:18453`. Edge `127.0.0.1:18453`, relay `127.0.0.1:19453`, page `127.0.0.1:18133`. Driver `driver.mjs`, launcher `run.sh`, record `summary.json`.

A waiting tile with `videoWidth` 0 is not counted as playing. Alice's own `bob/cam` tile was still that waiting state when her status became "In the room." The first counted sample is Bob's `alice/cam` tile after the caption was "Playing." and the width was nonzero.

Observed:

- Before Join the fragment was empty, the open-room notice was present, and camera and peer-connection counts were 0.
- Alice's first `POST /whep/r1/bob/cam` was 409. Bob then joined. The first counted decode of `alice/cam` was 640×360, caption "Playing.", left `[200, 49, 120]`, right `[30, 160, 159]`, audio peak 439 Hz, rms 0.0095, audio and video tracks live. Edge accepted `alice/cam` and `bob/cam` at cap 2500000 (`moq-lite-06`).
- Replace moved Alice from generation 1 to 2. Sessions changed from `/session/cb6beab0-519f-4bbb-8d0a-a86633e694fb` and `/session/1b44ec69-24b6-4d12-96a7-6b10112dc8ca` to `/session/7fd48340-c777-41c6-bd0e-f9c88f6c2c49` and `/session/2ce6c165-5f7f-45e3-8f77-70def5c19c95`. The previous local tracks were `ended`. The preview stream was the new live audio and video tracks. Bob's tile decoded again at 640×360, "Playing.", same colors and 439 Hz, on new live track ids.
- Autoplay recovery was forced in the harness by rejecting unmuted `play()` once. The tile caption became "Playback is blocked. Use Play media." at width 0, and `#resume` was shown. That width-0 sample is not a playing result. After the Play media click the same tile was "Playing." at 1280×720, same colors, 439 Hz, live tracks. `#resume` stayed shown: the click handler hides it only when no tile is still marked blocked, and that check runs before `play()` resolves.
- Renew with Bob's token: status "This token cannot publish that path.", renewal field empty, sessions unchanged, camera count unchanged. The new admit was `POST /admit` 403. No redirect (`redirected` false, authorization present).
- Renew with the second Alice token: status "In the room.", new sessions, and Bob decoded `alice/cam` again at 1280×720, "Playing."
- Leave: status "Left the room.", local tracks empty, incumbent sessions empty, peer connections 0. `status().deletes` lists eight HTTP 204 results, covering the generations cleaned up during the run. The edge log does not print DELETE lines.
- Refusals, camera count 0: empty fragment "A token is required before the camera can open."; `not-a-jwt` and the ttl=2 token "This token is not valid."
- After each Alice republish the edge logged `session ended err=mux error: moq: unroutable role="whep server"`. Bob still reached a later "Playing." decode. Same-path handover stays non-atomic.
- Console lines were favicon 404, the expected 409, and the expected 403.

`.15` stays open.
