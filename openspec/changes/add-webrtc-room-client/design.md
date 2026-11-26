# add-webrtc-room-client design

Gateway contract: `add-webrtc-edge` design D2–D4. Comparison order: `lib/mjolnir/relay/room_join.ex`.

## D1. Admission

```text
admit(mintToken, expectedRoot, operation, broadcast) ->
  POST {configuredOrigin}/admit
  Authorization: Bearer mintToken
  X-Mjolnir-Root: expectedRoot
  {"operation","broadcast"}
```

The fetch is the module's. Its result is trusted because the TLS origin is the configured one, not because the JSON contains `ok`. `Cache-Control: no-store` is required on the response; the page also does not store the body in a URL, a log line, or `localStorage`. The token stays in memory. The fragment is stripped on load and not sent as `Referer` (`Referrer-Policy: no-referrer`).

Local comparison after a 200, using the returned `root` as the admitted root and refusing if the returned `broadcast` or `operation` differs from the request:

1. Expected root ≠ admitted root → `unexpected_root`.
2. Mint `root` ≠ admitted root → `response_root_mismatch`.
3. Open root and mint `kind` omitted or not `open` → `kind_mismatch`.
4. Protected root and mint `kind` omitted → allowed for kind (the helper treats omission as protected).
5. Asked `open` and class `protected` → `open_refused`.
6. Asked `protected` and class `open` → `protected_refused`.

This page's ask is `open`. Step 1 fires before step 5. An invitation for `t/<owner>/~open/<room>` and an old mint rooted at `t/<owner>/<room>` is `unexpected_root`, not `open_refused`.

Non-200 from `/admit` is `unauthenticated_identity` for 401/403 and `setup_failed` for a network error. No camera.

WHIP and WHEP repeat the bearer and header. They do not resend the `/admit` JSON as a credential.

## D2. Candidate

```text
generation: number
abort: AbortController
tracks: MediaStreamTrack[]  // owned; a shared device track is refcounted
pcs: RTCPeerConnection[]
sessionIds: string[]
timer: exp timer bound to this generation
```

Arm `exp` and abort before `getUserMedia`. After every await, if generation ≠ current, or `now >= exp`, or abort fired, drop this candidate only.

WHIP failure before commit: drop candidate, incumbent unchanged.
Commit: WHIP `201`, `setRemoteDescription` ok, and the exp check passed. Peer WHEP `409 not_started` does not roll back. Peer `403` or `codec_unavailable` marks that path failed and does not retry. Peer transport errors and `not_started` retry at `retryMs` with exponential backoff capped at 30 s, at most one in flight per path.
ICE not `connected` within 10 s: close that PC, DELETE that id, retry if the error class is retryable.

`renew` / `replace` build a new generation. DELETE old ids only after the new WHIP has committed. On failure, abort the new generation and leave the old timer and PCs. The new generation's timer is the only one that closes the new PCs. Stop a track only when its refcount hits zero.

Explicit leave aborts every generation and DELETEs every id still owned.

When a named-peer PC fires `connectionstatechange` to `failed` or `disconnected` past the ICE timeout, retry that path until `exp`. Document in the UI if the retry does not restore the picture: "the other side must publish again." Do not claim publisher replacement is followed automatically.

## D3. Slice versus done

First green slice: one Chromium, notice before the camera prompt, one WHIP, one invitation path, colours and tone, the refusal cases, partial renew, stale generation, old timer, DELETE. Not done: `.14`, Safari phone, three networks, eight PCs.

## D4. Licence

MIT page and module. No import from the AGPL host tree.
