# Arch media proof, 2026-11-27

Host: Framework (`dorje@100.121.90.25`), Arch, `Linux x86_64`. This is not an Ubuntu binary.
Chromium 156.0.8078.79. Pages served on `127.0.0.1:18125` (18124 was already taken by an older harness).
Disposable relay `127.0.0.1:9443`, edge `127.0.0.1:8444`. Tokens from `Mjolnir.Relay.Mint.issue` under `MIX_ENV=test`. No tokens are stored here.

The run that produced the playback numbers used:

```
5502d0c1019f398682ee53ee8fc5b53105d201462ce46775f89c895e74a63bbc  mjolnir-edge
812c76ed185d4f3216e1f735b4cf2e07daf129fffe1512cfda928cf3ba2782b9  mjolnir-relay
```

A later rebuild only added pool log lines and hashes to `a8e6b9b7b6b7bdf75c7963e9fee6565e0271a79cc91fde778b9403a8cff8d055`. It was not re-run through Chromium.

`POST /admit` returned 200 with the open root, `publish`, and `alice/cam`. UDP socket count was 2 before and 2 after, so admit did not open a media socket.

Publisher and player used different participants, so they dialed two relay sessions. The same token is one session: two overlapping WHIP legs (`alice/cam` and `alice/side`) added `concurrent_new_sessions=1`.

Playback of `alice/cam` (`PLAY_EXIT:0`): VP8 and opus, `framesDecoded` 279, left `[200,49,120]` vs `0xC83278`, right `[30,160,159]` vs `0x1EA0A0`, audio peak 439 Hz, rms 0.088. Chromium scaled the 1280x720 y4m; the decoded frame was 640x360. A subscriber that joined about 8s late got the same colors and no tone (`audioRms` 0) while groups were already evicted (`Stream(Old)`).

DELETE of the publisher id: other token 403 `forbidden`, owner 204, repeat 204, unknown id 404 `not_found`. The player id: other token 403, owner 204, repeat 204.

A 12s `short` token published `short/cam`. A bob subscriber matched video and 439 Hz. After expiry the relay logged `authorization token expired` and a new WHEP of that broadcast returned HTTP 503 `setup_failed` / `unroutable`.
