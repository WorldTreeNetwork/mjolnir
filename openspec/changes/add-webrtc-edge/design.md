# add-webrtc-edge design

Pin: moq `4a6f522483168ace392718d68b58a402533c897d`, `moq-webrtc` 0.3.12. Spike: `spikes/finding.md`. Relay assess: `native/mjolnir_relay/src/lib.rs` (`assess` returns `Result<Grant, Refuse>`). Open root: `t/<owner>/~open/<room>`. Protected root: `t/<owner>/<room>`.

## D1. Process

`mjolnir-rtc` is its own binary and systemd unit, user distinct from the relay. It reads the relay's public verify set. It holds no mint key. Default off. Installing or removing it is the same class of flag as `deploy.sh --relay`. This contract does not run that flag.

One UDP media port is added to `:published_port_reserved` so a VM cannot publish it. The port number is configuration, not a new token claim.

## D2. HTTP

- `POST /whip/<room>/<broadcast…>` publish.
- `POST /whep/<room>/<broadcast…>` play.
- `DELETE /session/<id>` drop a session this token admitted.
- `Authorization: Bearer` is the room token. `X-Mjolnir-Root` is the invitation's expected full root, exact bytes.
- CORS allows `Authorization` and `X-Mjolnir-Root` on those routes. No other origin privilege.

`<broadcast>` is relative to the token root (`alice/cam`). `<room>` is compared to the root's room segment. The owner is not in the URL. The URL is never concatenated into a MoQ path.

## D3. Order

Stop at the first failure. No relay dial and no SDP answer before step 7 succeeds.

1. Bearer missing or not a token: `401`.
2. `assess` on one key-set snapshot: failure `403 bad_token`. Log the reason class, never the token.
3. Classify the assessed root. Only literal `t/<owner>/~open/<room>` is open. Protected, a missing `~open` marker, and any other shape: `403 room_not_open`.
4. Wide root `t/<owner>` (no room segment): `403 room_not_open`, even if the URL contains `~open`.
5. URL room segment ≠ root room segment: `403 room_not_open`.
6. `X-Mjolnir-Root` missing: `400`. Present but not byte-equal to the assessed root: `403 unexpected_root`. No case-folding, no percent-decoding of the header.
7. WHIP requires the publish grant to match the broadcast. WHEP requires the subscribe grant. Else `403 forbidden`.
8. `exp` already past: `403 bad_token`.
9. Open the relay session with this token. WHEP has no catalog: close it and return `409 not_started`.
10. Build the answer. Video offered but no overlapping catalog video codec: close and return `409 codec_unavailable`.
11. Return `201` with the answer and a session id. Drive the WebRTC task until the PC ends, the relay session ends, or `exp`.

Replacement and renewal repeat 1–11 with the new bearer. `DELETE` of the old id happens only after `201`. A failed new POST leaves the old session.

`assess` failure handling matches the relay: a bad or draining key set fails closed for new admissions. This unit reloads the verify set on the relay's interval (at most five seconds) and uses the snapshot taken at step 2 for that request. Emergency revoke remains the relay's drain, which closes the relay session and therefore this task.

## D4. What this is not

`Mjolnir.Relay.RoomJoin.check/4` compares an invitation, an asked kind, a mint body, and a trusted admission tuple inside Elixir tests. The gateway does not call it. The browser does not call it. Both must enforce the same equalities at their own boundary. The gateway's trusted root is only the root `assess` returned for this bearer.

## D5. Media path

WHIP and WHEP origins come from the relay session. The keyframe patch, when `.12` lands, may ask the WHIP encoder on a period. It must not take a local subscriber origin. Metering of viewer bytes stays on that relay subscribe. Per-owner caps are `.4` and are not claimed here.

## D6. Evidence already in hand

| Check | Result |
|---|---|
| Chromium WHIP to MoQ, VP8/H.264/VP9/AV1 | GO, `spikes/logs/claim1-*` |
| WHEP in Chromium and Firefox | GO except Firefox AV1 video |
| Two WebRTC plus one native participant | GO, `claim3-room.log` |
| Foreign room, no token, expiry closes the PC | GO, `claim4-*` |
| Protected WHEP | HTTP 422 generic in the spike; this contract requires `403 room_not_open` |
| 8× WHEP CPU | about 47% of one M1 Max core at 720p |
| Linux `x86_64` build | not run (SSH timeout). Owed before the unit file is called done |
| Safari | not run |

## D7. Smallest slice after accept

One binary, the three routes, the order in D3, a disposable relay, real `Mint.issue` open and protected tokens. Prove: open WHIP and WHEP exchange the spike's coloured frames through the relay; protected, wide, mismatched `X-Mjolnir-Root`, and old-mint (no `~open`) return the status above with no SDP and no relay session; expiry closes DTLS. Ubuntu build of that binary on the Framework laptop. Then stop. The page is `.15`.
