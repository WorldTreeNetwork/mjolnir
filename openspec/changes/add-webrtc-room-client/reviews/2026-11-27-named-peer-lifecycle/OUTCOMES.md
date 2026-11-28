# Named-peer lifecycle measurements

Raw files in this directory are the audit record. Page source was not changed for this run. Gateway binaries were the accepted `4bd94d1d` build and were not rebuilt. `.15` stays open.

`summary.json` is the Playwright record of button clicks on `page/room.html`. `edge-events.txt` is the sanitized edge log. `identities.txt` and `page-hashes.txt` name the binaries and the served files. `mint.txt` records root length and `exp` only. `run.sh` and `driver.mjs` are the harness. Tokens stayed in `/tmp` on Framework and are not in these files.

Served `page/boot.js`, `page/room.css`, `page/room.html`, and `src/room.js` match `eb781150`. Served `page/config.js` is the harness assignment `window.MJOLNIR_ROOM_ORIGIN = "http://127.0.0.1:18451"`.

Chromium 156.0.8078.79 clicked `#join`, `#replace`, `#renew`, and `#leave`. Synthetic source was the existing 1280×720 y4m (left `0xC83278`, right `0x1EA0A0`) and 440 Hz wav.

Observed:

- Fragment hash was empty before Join. Notice text was present. `getUserMedia` and `RTCPeerConnection` counts were 0.
- Alice joined first. First `POST /whep/r1/bob/cam` was 409. The tile read “waiting — the other side must publish again”. A later `POST` on that path was 201.
- Bob joined and decoded `alice/cam` at 640×360, left `[200, 49, 120]`, right `[30, 160, 159]`, audio peak 439 Hz, rms 0.0095, tracks audio and video. Edge: `moq-lite-06` webtransport, `whip publish accepted` for `alice/cam` and `bob/cam` at cap 2500000.
- `#replace` on Alice kept status “in the room”, moved the incumbent from generation 1 to 2, opened a new WHIP session, and `DELETE`d the previous two sessions with 204. Camera count went from 1 to 2.
- Bob’s tile still said “playing” at 640×360 after that replace. Pixels were not sampled again.
- `#renew` with Bob’s token returned status `forbidden`. The only new request was `POST /admit` 403. Camera count stayed 2 and the PeerConnection count stayed 5. No `DELETE` followed that 403. `sessionsUnchanged` in `summary.json` is false because the in-flight 409 retry added `/session/8fa14f45-518c-4b9e-8979-c1fc61b09b98` after the replace snapshot and before the 403. The incumbent id stayed 2.
- `#renew` with a second Alice token returned “in the room”, incumbent 4 (the forbidden attempt consumed generation 3), new sessions, and two more 204 deletes of the generation-2 sessions.
- `#leave` set status `left`, tracks 0, sessions empty, and `DELETE` 204 of the two generation-4 sessions.
- Separate pages, clicked `#join` only: empty fragment `no_token` with zero requests and zero camera; `not-a-jwt` and a ttl=2 token used after 3.5s both `bad_token` from `POST /admit` 403, camera 0, PeerConnection 0.
- No page errors.

The Replace button resubmits the fragment token. A different token is only available through the renewal field. The 11 node tests were not re-run as this proof.
