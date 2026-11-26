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

This page's ask is `open`. Step 1 fires before step 5. Those are pure comparator outcomes only. The real open-only gateway refuses a protected token with `room_not_open`; it never returns an admitted protected root.

Preserve known typed errors from the configured gateway: room_not_open, unexpected_root, forbidden, bad_token, no_token. Unknown/malformed refusal is unauthenticated_identity; network failure is setup_failed. Real old-mint and protected-invitation tests expect room_not_open, not synthetic comparator results. No camera.

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

Before camera or any PC/media side effect, require finite exp > current time, valid ownership and no abort. Check again after every await. Admit selfPath for publish and EACH named peer for subscribe first, binding results to immutable token, expected root, operation, canonical path and attempt. Expired-on-arrival admission never prompts camera; late permission streams are stopped. A candidate and a committed incumbent have separate live ownership states: starting a candidate does not invalidate incumbent retries or expiry callbacks. Only superseded candidate completions are discarded.

WHIP failure before commit: drop candidate, incumbent unchanged.
Commit: WHIP `201`, `setRemoteDescription` ok, finite unexpired admission, and ICE connected within min(exp, now+10s). This is transport readiness, not proof of media. Peer WHEP `409 not_started` does not roll back. Peer `403` or `codec_unavailable` marks that path failed and does not retry. Peer transport errors and `not_started` retry at `retryMs` with exponential backoff capped at 30 s, at most one in flight per path.
Candidate publisher ICE timeout: abort the entire candidate, close its PCs, DELETE its ids and release owned tracks/timers; preserve incumbent. Return setup_failed; no automatic whole-call replacement retry. Peer-only transient failure uses its bounded retry policy.

`renew` / `replace` build a new generation. DELETE old ids only after the new WHIP has committed. On failure, abort the new generation and leave the old timer and PCs. The new generation's timer is the only one that closes the new PCs. Stop a track only when its refcount hits zero.

Explicit leave aborts every generation and DELETEs every id still owned.

When a named-peer PC fires `connectionstatechange` to `failed` or `disconnected` past the ICE timeout, retry that path until `exp`. Document in the UI if the retry does not restore the picture: "the other side must publish again." Do not claim publisher replacement is followed automatically.

## D3. Slice versus done

First green slice: one Chromium, notice before the camera prompt, one WHIP, one invitation path, colours and tone, the refusal cases, partial renew, stale generation, old timer, DELETE. Not done: `.14`, Safari phone, three networks, eight PCs.

## D4. Licence

MIT page and module. No import from the AGPL host tree.

## D5. Limits and regression cases

Admission covers every intent before media; changed credential/path/operation requires a fresh result. Media POST reassesses keys; revocation can race a camera prompt after successful preflight, so no impossible continuous-revocation guarantee is made.

Pinned WHIP announces inside accept before HTTP delivery. Keeping incumbent PCs until readiness does not make relay publication selection atomic. Test same-path candidate answer failure, remote-description failure and ICE timeout with existing AND new subscribers. Report non-atomic selection honestly; no bypass or seamless handover promise. Test incumbent callbacks during a failed candidate, and real peer termination/resubscribe on publisher replacement.

retryMs must be finite in [1000,30000]; backoff caps at 30000. Validate relative paths with gateway grammar/bounds before requests; encode without introducing queries/fragments. DELETE only validated same-configured-origin /session/id Locations, with the admitting bearer. Missing/foreign Locations refuse cleanup requests and surface failure; server ownership deadlines still reclaim resources.
