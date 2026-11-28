# Code/UI repair measurements

The historical probe file `../2026-11-27-code-repros.mjs` was not edited. Before the repair it was 15 pass (defects reproduced). After the repair the same assertions are 15 fail. The positive coverage is `native/mjolnir_room/test/regressions.test.js` plus the original 11 tests: 27 pass.

`browser.json` is the Chromium 156.0.8078.79 run of `driver.mjs` against a local HTTP fixture, not the accepted gateway. Authorization values are recorded only as present or absent. The 404 console line is a missing favicon. The 409 and 403 console lines are the fixture's `not_started` and `forbidden` responses.

Observed through the page buttons:

- Expired admission: status "This token is not valid.", camera count 0, fragment empty, notice present.
- Join: `POST /whep/r1/bob/cam` was 409 and then 201. Status became "In the room." Sessions `/session/s1` and `/session/s2`. At that sample the tile still said the other side must publish again and `videoWidth` was 0.
- Replace deleted `/session/s1` and `/session/s2` with 204 and opened `/session/s3` and `/session/s4`. Unmuted `play()` was rejected by the harness. The Play media button was shown. After that click the tile said "Playing."
- Renew with the other participant's token: admit was refused, the renewal field was cleared, camera count stayed 2, and the session list stayed `/session/s3` and `/session/s4`.
- Leave cleared the local video and peer tiles in 44 ms while DELETE of `/session/s3` and `/session/s4` was still unanswered. The later status was "Left the room. The server has not confirmed cleanup."

Same-path relay handover stays non-atomic. The accepted gateway was not rebuilt or changed. `.15` stays open.
