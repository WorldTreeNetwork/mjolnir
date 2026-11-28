# Named-peer slice

MIT page and module: `native/mjolnir_room`. It does not import the AGPL host. `mjolnir-rurh.15` stays open. `.14`, Safari-on-phone, three networks, and eight PeerConnections are not this slice.

`node --test test/room.test.js` in that directory: 11 passed. Those tests cover absolute and `..` paths with zero fetches, `room_not_open`, `unexpected_root`, omitted-kind `kind_mismatch`, expired-on-arrival with zero camera and zero PeerConnections, `not_started` retry at `retryMs`, WHIP `403` stopping tracks, a failed replacement leaving the incumbent session, a late `getUserMedia` from the superseded attempt, an old expiry timer that does not close the new generation, DELETE of `/session/{id}` with the admitting bearer, a foreign Location refused before commit, `codec_unavailable` with no retry, and a network failure as `setup_failed`.

## Browser against the accepted gateway

Binaries are the already accepted `4bd94d1d` build (`/tmp/mj13-4bd-tgt`). The gateway source was not rebuilt and was not changed. Relay `127.0.0.1:19449`, edge `127.0.0.1:18449`, page `127.0.0.1:18128`. `Mint.issue` (`kind=open`, root length 54). Chromium on Framework with the synthetic 1280×720 y4m and a 440 Hz tone.

The notice “This room is open. The host can read the media.” was in the document before Join, and `getUserMedia` observed that same text. The fragment was empty after load. No page error.

Alice joined with peer `bob/cam`. Bob joined with peer `alice/cam`. Both statuses were “in the room”. Edge log: `connected peer=https://localhost:19449 transport=webtransport`, then `whip publish accepted` for `alice/cam` and `bob/cam` (`cap=2500000`).

Bob’s tile for `alice/cam` decoded both tracks. Frame 640×360 (not the 1280×720 source). Left `[196, 51, 118]` against `0xC83278`, right `[33, 159, 155]` against `0x1EA0A0`, audio peak 439 Hz, rms about 0.028.

The page says the relay does not follow a replaced publisher by itself. Same-path publication is selected inside WHIP accept, so a failed candidate does not promise that remote subscribers snap back.

A Mac preview was not used. The gateway listens on the Framework loopback, and that preview cannot open it.
