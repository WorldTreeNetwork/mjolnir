# add-webrtc-room-client design

Reference comparison: `lib/mjolnir/relay/room_join.ex` (`check/4`). The page reimplements those equalities in TypeScript. It does not load Elixir. Admission is trusted only when this module verified the token. A mint JSON `root` alone is not admission.

## D1. Entrypoints

```text
join(input) -> Promise<Session | Refusal>
replace(session, input) -> Promise<Session | Refusal>
renew(session, input) -> Promise<Session | Refusal>
teardown(session, reason) -> void
```

`input` is `{ expectedRoot: string, asked: "open" | "protected", mint: { token, root, kind? }, jwks }`.

`join` order:

1. Verify `mint.token` with `jwks` (EdDSA, `exp`, `iat`, root shape). Failure: `{ error: "unauthenticated_identity" }`. The verified root and the verified token bytes are the admission. A caller-supplied `{ ok: true }` is not accepted.
2. Compare as `RoomJoin` does: expected root, asked kind, mint `root` and `kind`, admission root and token. Same error atoms (`unexpected_root`, `open_refused`, `kind_mismatch`, `response_root_mismatch`, `invalid_root`).
3. If asked is `open` and the class is open, render the host-readable notice. If the check failed, render the refusal and return. Do not call `getUserMedia`.
4. `getUserMedia` only after step 2 succeeds.
5. POST WHIP with `Authorization` and `X-Mjolnir-Root: expectedRoot`. On a non-201, `teardown` and return the status. Do not attach the local stream to a PeerConnection that has no answer.
6. For each invitation path other than self, POST WHEP the same way. `409 not_started` leaves that tile empty and retries on the invitation's interval until `exp`. It does not fail the whole join.
7. Arm a timer at `exp` that calls `teardown`.

`replace` and `renew` run steps 1–6 with the new mint. They DELETE the previous session ids only after every new POST that this call needs has returned 201. A refusal at step 1 or 2 does not DELETE and does not stop tracks.

`teardown` stops every track, closes every PeerConnection, and clears the timer. It is safe to call twice.

This page's `asked` is `open`. A protected invitation is `open_refused` here; the encrypted client is `.5`.

## D2. Copy

One sentence, visible before the camera prompt: "This room is open. The host can read the media." No padlock. No "end-to-end" wording.

## D3. First slice versus done

Done for this node is three people on different networks, one of them Safari on a phone, each seeing and hearing the others, plus a MoQ participant in the same open room. The first build after accept is D1 against a local `.13`: one Chromium page, one named peer path, coloured-frame check, and the refusal tests. That slice is not node completion. `.14` still owns the live roster. Eight PeerConnections and Safari stay unchecked spikes (`peerconnections-8`, `safari-whep`).

## D4. Shell to reuse

`spikes/pages/rtc.js` in `add-webrtc-edge` already posts WHIP and samples frames. Lift the POST and the frame sampler. Add D1 in front of them. Do not copy the spike's permissive "any room segment" assumption.

## D5. Licence

The page and module are MIT, same as `native/mjolnir_client`. They do not import the AGPL host.
