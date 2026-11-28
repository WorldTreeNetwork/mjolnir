# Re-review repair against the accepted gateway

Product changes are in `native/mjolnir_room`. The historical probe file and `2026-11-27-rereview-72ec611-probes.mjs` were not edited. Gateway binaries were not rebuilt.

`node --test native/mjolnir_room/test/room.test.js native/mjolnir_room/test/regressions.test.js` is 39 pass. The unchanged re-review file is 9 pass and 10 fail. The 8 PASS probes still pass. Ten DEFECT probes fail because the bad behavior is gone. One DEFECT probe still passes: it calls `onRemoteTrack` twice with attempt 1 and no generation id, so the page cannot tell the calls apart. The production callback passes the generation id, and `regressions.test.js` covers that call.

Served hashes from the last Chromium run: `src/room.js` `10f99ed76dc8ec5b5c6432b6ab48c3300c87fdd41a6bde9d67102441b0624c92`, `page/boot.js` `c636a6b977804e45bb65f8cc9fb71687236212b35b76032dc571cf30f9149791`. Gateway binaries remain sha256 `57a21527…e343` and `9c24f67c…e344`. Chromium 156.0.8078.79. Mint root length 54. `config.js` is the harness origin `http://127.0.0.1:18454`.

Real media, counted only at caption "Playing." and nonzero width:

- First Bob decode of `alice/cam`: 640×360, left `[200, 49, 120]`, right `[30, 160, 159]`, 439 Hz, rms 0.0095.
- After replace, and after the valid renew: same colors, 640×360, caption "Playing." The tone measurement on those two samples was 0 Hz and rms 0. That is not a restored-tone result.
- Autoplay hook rejected unmuted `play()`. The tile was "Playback is blocked. Use Play media." at width 0. After Play media, the caption was "Playing." at 640×360 with the same colors and 439 Hz, and `#resume` was hidden.
- Bad renew status: "This token cannot publish that path."
- Leave: "Left the room." and an empty session list. The page recorded eight DELETE 204s.

Labeled hooks on the same page origin and the same gateway, not the fixture:

- Peer-connection constructor throw: status "The room could not be connected.", no WHIP request, camera tracks `ended`.
- WHIP 201 whose `text()` then throws: DELETE `/session/67ba8a7f-5519-487f-a5c3-3eb6c040d879` returned 204.
- Leave while ICE gathering was forced to stay `gathering`: status "Left the room."
- Shared `getUserMedia` tracks, replacement `createOffer` throws: incumbent stayed 1, those tracks stayed `live`, status "The room could not be connected."
- DELETE left hanging, then Join again: status stayed "In the room."
- Twenty-second token: status "This token is not valid.", no tiles, no local tracks.

Same-path handover stays non-atomic. `.15` stays open.
