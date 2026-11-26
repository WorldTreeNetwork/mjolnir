# add-webrtc-edge design

Pin `4a6f522483168ace392718d68b58a402533c897d`. `assess` is `lib.rs:215`: token, path, `&KeySet`, `max_ttl` → `Result<Grant, Refuse>`. It does not load keys and does not read a drain flag. `Grant.root` is the authenticated root string (`grant_from`, `lib.rs:133`). `load_verify_keys` (`lib.rs:61`) rejects a private key, a missing or duplicate `kid`, a disallowed algorithm, and an empty set.

`moq_webrtc::server` exposes `Response` with the answer, an id, and `run`. Drop unregisters. There is no public method that sends a DTLS `close_notify`. Catalog resolve inside WHEP waits up to five seconds (`server/whep.rs`). That wait needs a relay connection. "No session" means the `Response` was dropped before `run`, and the registry has no id.

## D1. Snapshot

Configuration: verify-set path, `max_ttl` equal to the relay's token ceiling, relay URL, page origins, media UDP port.

Apply `key_file_trusted` ownership/mode checks before `load_verify_keys` at initial load and every reload. Reload the verify set at least every five seconds. The request snapshot is that set plus a bool `admissions_open`. `admissions_open` is false when the last reload failed or the process was told to drain. A failed reload does not install the bad file. New admissions then fail `403 bad_token`. Sessions already admitted keep running until `exp` or until their relay connection closes. Emergency drain closes relay connections; each leg's `run` ends because that connection ended. There is no per-user kick.

`assess` is called with the configured `max_ttl` and the snapshot's keys. The path argument is empty at this step. Path confinement is the separate grant match below, on the broadcast path the handler parsed. The original `grant.root` is what later steps compare. Nothing reparses the JWT.

## D2. HTTP

Origins: the configured list. If the list is empty, same-origin only. `Access-Control-Allow-Origin` echoes a listed origin, never `*` when `Authorization` is allowed. Methods: `POST`, `DELETE`, `OPTIONS`. Allowed request headers: `Content-Type`, `Authorization`, `X-Mjolnir-Root`. Exposed response header: `Location`. Preflight max-age 600. No `30x` that carries the bearer.

| Status | `error` | When |
|---|---|---|
| 401 | `no_token` | missing or empty bearer |
| 400 | `bad_request` | missing root header, bad JSON, bad path |
| 403 | `bad_token` | `assess` refused, expired, admissions closed |
| 403 | `room_not_open` | not the open shape, or wide `t/<owner>`, or URL room segment differs |
| 403 | `unexpected_root` | header present and not byte-equal to `grant.root` |
| 403 | `forbidden` | grant does not match the operation's broadcast |
| 409 | `not_started` | Before expiry: WHEP catalog timeout, absent broadcast, or no rendition (D8) |
| 409 | `codec_unavailable` | offer had video and the built answer has no usable accepted video section (port zero or inactive is rejected) |
| 503 | `setup_failed` | Before expiry: dial/other setup timeout or answer-write failure; catalog deadline is 409 (D8) |
| 204 |  | DELETE owned by this bearer |
| 404 | `not_found` | DELETE unknown id |
| 403 | `forbidden` | DELETE with a different bearer |

Bodies are `{"error":"<code>"}` except `201` (SDP body, `Content-Type: application/sdp`, `Location: /session/<id>`) and `204`.

Path: take the broadcast remainder, reject a backslash, reject `%2f` / `%2F` before decoding, percent-decode once, reject empty, `.`, `..`, a second slash-escape, or any segment that is empty. The string passed to `grant.publish` or `grant.subscribe` is that decoded relative path. Tests cover encoded slash, `%252f`, and backslash, and assert the moq path equals the decoded form.

## D3. Order

One function for `/admit`, WHIP, and WHEP. `/admit` completes steps 1–8 and returns `200 {"root","exp","operation","broadcast"}` with `Cache-Control: no-store`. It does not dial.

1. Bearer or `401`.
2. Snapshot. If not `admissions_open`, `403 bad_token`.
3. `assess`. Map `Refuse` to `403 bad_token`. Keep `grant.root` and `grant.expires`.
4. Classify. Open is only `t/<owner>/~open/<room>` with a canonical 32-byte base58 owner and room exactly `[A-Za-z0-9_-]{1,64}`, per RoomClass. Else `403 room_not_open`. A root of exactly two segments (`t/<owner>`) is wide: `403 room_not_open`.
5. Media routes require their URL room segment to equal the root room. `/admit` has no URL room: use the independently expected full root header, checked in step 6.
6. `X-Mjolnir-Root` missing → `400`. Else byte-compare to `grant.root`. Mismatch → `403 unexpected_root`. No decoding.
7. `/admit` requires JSON operation exactly `publish` or `subscribe` plus a canonical broadcast, and matches that operation against the grant. WHIP: `grant.publish` matches the parsed broadcast. WHEP: `grant.subscribe` matches it. Else `403 forbidden`. The relay session's subscribe scope is what stops a later catalog sibling outside the grant. This contract does not add a second authorizer.
8. If `now >= exp`, `403 bad_token`.

Then, WHIP and WHEP only:

9. Set the deadline `min(exp, now+5s)` BEFORE pool acquisition. Bound acquisition and dial by this deadline and request cancellation. Take or dial the connection for these exact token bytes. Dial uses verified TLS (webpki roots). Failure leaves no hold; apply D8: expiry 403, pre-expiry dial failure/deadline 503.
10. Increment the refcount. The deadline from step 9 remains unchanged. Race relay closure and that deadline against catalog resolve and answer build.
11. WHEP: catalog timeout, missing broadcast, or no rendition → drop the unrun `Response`, decrement, and apply D8: expiry 403; before expiry `409 not_started`.
12. If the offer contains video and the answer has no usable accepted video section (port zero or inactive is rejected), drop the unrun `Response`, decrement, `409 codec_unavailable`. WHIP does not look for a source catalog.
13. If `now >= exp` or the relay connection closed or the deadline fired, drop, decrement, and apply D8: expiry `403 bad_token`; before expiry catalog deadline `409 not_started`, other deadline or relay close `503 setup_failed`.
14. Insert `{id, token_bytes, response}` and return `201`. `run` starts only after the `201` is queued. If the write to the client fails, drop and decrement as if step 13 failed.

A refusal never deletes another id. Decrement to zero closes the connection. `exp` on the connection closes it even if a refcount is non-zero, and every id on that token is dropped. That is the whole-token close. It does not run for a different token.

## D4. DELETE and replacement

`DELETE` looks up the id. Wrong token → `403` and no change. Owned id → drop that `Response` if it is still the map's value, decrement, `204`. Retain an ownership tombstone (credential digest, id, expiry only) until exp+30s; same-token repeat DELETE during that horizon → `204`, then `404`. No bearer bytes or media resources remain in the tombstone. Unknown id → `404`.

Replacement is a new POST with a new bearer. It gets a new connection. The caller DELETEs the old id only after the replacement WHIP reaches bounded ICE readiness, not merely `201`. A failed POST does not DELETE.

## D5. Acceptance of "closed"

Dropping `run` stops forwarding. That is the acceptance test: after `exp` or DELETE, the relay session for that hold sends no further media. The spike saw browsers notice 6–7 s later. This contract does not require an immediate DTLS `close_notify`, because the pinned `Response` has no such method. A patch that adds one is a separate change.

## D6. Proof the first slice must show

Real `Mint.issue` open and protected tokens. Wide roots from a test signer, not from `Mint.issue`. Disposable relay.

- Open WHIP and open WHEP: coloured frames and the fixture tone both ways. One connection per token while two legs share it (`refcount` observable in the test log).
- Protected, mismatched header, foreign broadcast, malformed grant, expired: status from D2, and a dial counter that stayed zero. `/admit` included.
- Expiry during the catalog wait: no `201`, no registered id, all same-token legs stopped and other-token legs unaffected.
- Failed renewal: old id still runs.
- Invalid key file after a good load: new POST `403`, old session runs. Then process drain: relay connections closed, legs stop forwarding.
- DELETE with the admitting bearer, a repeat, and a different bearer.
- Encoded `%2f` does not become a slash in the moq path.

Ubuntu 24.04 build of this binary is an implementation gate and is not claim 8. Claim 8 is Arch. Safari, eight PeerConnections, and Hang watch stay on their existing gates.

## D7. Order relative to other nodes

Fresh accept of `.12` and of this contract, then `.12` K0–K1 and the ingest patch, then this slice. `.12` still blocks the whole `.13` node. The named-peer page (`.15`) may start after this slice is green; `.14` still blocks calling `.15` done.

## D8. Setup ownership and precedence

Pool acquisition is single-flight per exact token, with owned reservations. Last-release/new-acquire, simultaneous POSTs, cancellation and relay-death races must not create two connections or orphan a hold. Each hold is released once. The registry owns a cancellable runner after `Response::run(self)` consumes the response. Normal completion removes its entry; cancellation or failed answer delivery cancels its runner. Before a Response exists, cleanup still releases the candidate reservation.

Expiry wins every setup race (`403 bad_token`, all same-token resources stop). Before expiry, an outer deadline during catalog resolution is `409 not_started`; dial/other setup deadline is `503 setup_failed`. Candidate timeout before expiry preserves same-token incumbents. A video offer requires at least one usable accepted video section in the answer, not merely an m=video line; test pinned port-zero and inactive answers.

Canonical broadcast validation rejects malformed escapes, encoded slash, dot segments, and backslash before AND after one decode (including %5c); reject second encoded separators. Enforce moq's 4096-byte path bound and depth <=32 including the effective root. Assert exact validated string reaches moq. New operations repeat trusted-file/key/profile/grant checks even for pooled tokens; existing legs retain their admitted expiry.

Tests cover denied publish and denied named-peer subscribe at /admit with zero dial/SDP, single-flight ownership races, candidate-only timeout versus whole-token expiry, normal runner completion, failed answer writes, bounded DELETE tombstones and pinned rejected-video answers. `/admit` echoes authenticated root, exp, operation and canonical broadcast only after all checks. Protected/wide roots yield room_not_open before expected-root equality; never fabricate protected success for client tests.
