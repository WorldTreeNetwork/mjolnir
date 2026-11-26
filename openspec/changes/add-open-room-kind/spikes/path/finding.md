# Path-marker spike (2026-11-26)

Local harness only. Dummy EdDSA key `spike-kind`, generated in the process. Pinned moq `4a6f52248` via the relay crate's lock. The relay process is `open-room-kind-spike relay`: production `spawn_web_decider` and `TokenPolicy`, not the claim route. Certificate is a 10-day self-signed ECDSA P-256 leaf. No production host, no production key.

Logs kept: `../logs/path-offline.log`, `../logs/path-live.log`, `../logs/path-live-extra.log`. Added after send-back `fea6caf6`: `path-pair.log`, `path-follow.log`, `path-chromium.log`, `path-mint-http.log`. Scripts: `live.sh`, `pair-live.sh`, `follow-live.sh`, `chromium-live.sh`, `mint_http.exs`. Iroh wait is `spikes/rust` bin `iroh-pair`.

## Clock and old verifier

`path-offline.log` installs a kio `Manual` clock on the runtime and steps it. At t0+599, `KeySet::verify` is ok and `assess` admits. At t0+600, verify returns `token has expired` and assess is `BadToken` (verify fails before profile). A token with `iat` at t0+60, checked at t0+10, verifies and is then refused by profile as issued in the future. The same token on the host clock is expired. That is the current verifier, which is the deployed algorithm: no `kind` claim is involved, and a `kind` claim remains `BadToken` (claim spike C1, still true because this trial does not change the decoder).

`root_allowed` is true for `~open`. Literal open and protected paths admit. `%7Eopen` and `%257Eopen` are `path outside the grant`. Each token is refused on the other kind's path. A token rooted at `t/<owner>` is admitted on both.

## Native WebTransport

`path-live.log`, `wt-session` against `127.0.0.1`.

- Open root published `open-marker` (380 bytes) and a reader on that root received 14 frames, 266 bytes.
- Protected root published `prot-marker` (380 bytes) and received 14 frames, 266 bytes.
- Each cross-root session exited 1 with `Error: unauthorized` and no frames.
- `%7Eopen` and `%257Eopen` request paths, sent by `wt-session` without decoding, were `refused: unauthorized`.
- A subscribe-only token (`publish` empty) was `unauthorized` on publish.
- A token rooted at `t/<owner>` held a session on both the open URL and the protected URL.
- Announcements on the open root named `open-marker` only. Announcements on the protected root named `prot-marker` only.

## Iroh

Absolute paths, same tokens.

- Both publishers connected and reported 380 bytes.
- One protected own-read returned 1 frame, 19 bytes (`path-live.log`).
- One cross-subscribe returned `subscribe: unroutable`.
- The open own-read and the other cross-read did not finish within 12 seconds and were killed. `path-live-extra.log` repeated a paired open publish/read and a protected read of the open path: both readers were killed at 8 seconds with no frames, while the publisher still printed 570 local bytes.
- An open token's publish onto `t/<owner>/standup/stolen` also printed local bytes. The protected reader of that path produced no frames before an 8 second kill. Local `published bytes=` is not relay delivery. The cross-write is not shown to have landed, and it is not shown to have been refused, except for the one `unroutable` subscribe.

## Chromium

`path-live-extra.log`. Chrome for Testing 1255, `--headless=new`, `serverCertificateHashes` set to the harness leaf.

- Literal `https://127.0.0.1/<open root>?jwt=…`: `ready wrote=20` on a unidirectional stream of the bytes `chromium-open-marker`. That is WebTransport transfer. No MoQ subscriber observed those bytes. The MoQ frame evidence is the native `wt-session` read above.
- The encoded and double-encoded page URLs also readied. The page passes the relay URL in a query string and then hands it to `WebTransport`, which parses it again. `%7E` and `%257E` both become `~` before the request leaves the browser. Those two results are the literal session, not independent spellings. The native refusals are the encoded-path evidence.
- The HTTP mint was not called. `mix run` failed compiling this tree on an unrelated missing `Mjolnir.API.Auth.term_cookie/0`. `mint.ex` rejects a room segment outside `[A-Za-z0-9_-]{1,64}`, so `~open` cannot be a room name. That is source inspection, not an HTTP trace.

## After send-back fea6caf6

Pins stay moq `4a6f52248` and iroh-live `747b1bd`. The relay is still the spike binary's production decider and `TokenPolicy`. Tokens are redacted.

### Iroh, bounded

`path-pair.log`. Publisher writes a ready file after the relay link is connected and the broadcast is created, then the reader calls `Node::subscribe` with a 6 second bound.

- Open own-read: `frames=16 bytes=144 first=PAIR-OPEN`.
- Protected own-read: `frames=16 bytes=144 first=PAIR-PROT`.
- Each cross-root read, while that root's publisher was announcing, ended `subscribe-timeout call=Node::subscribe bound_s=6`. Not `unroutable`. The positive control received frames in the same run, so the timeout is the sibling path not becoming a route. It is not an explicit refusal string.
- A stolen publish from the open token onto the protected absolute path also printed local frames. The protected reader of that path hit the same 6 second `Node::subscribe` timeout. Local byte counts are not delivery.
- `path-follow.log`: a subscribe-only open token, while the open publisher was live, saw one announcement and it was only `t/<owner>/~open/standup/open-marker`.

### WebTransport operation inside an admitted session

`path-follow.log`. A token whose publish pattern is `p/**` was admitted (`held`) for both `p/track` and `q/track`. A subscriber on the same open root received `p/track` at 15 frames / 285 bytes and did not see an announcement for `q/track` (`frames=0 no-announcement`). The publisher of `q/track` still printed local bytes and exited 0. The relay did not surface an error to that publisher. Asking an admitted open session for `prot-marker` or `../standup/prot-marker` (`path-pair.log`) returned `no-announcement` while `open-marker` on that session delivered frames.

### Chromium MoQ

`path-chromium.log`. Headless Chrome for Testing, pinned `@moq/net` bundled from `4a6f522`, `serverCertificateHashes` of the harness leaf. The page posts the `URL` object it dials.

- Literal open URL: `moq-connected`, then `received path=open-marker frames=20 bytes=380 first=mjolnir-relay-frame`. That payload is the native `wt-session` publisher's frame, not a raw WebTransport write from the page.
- `new URL` of a string containing `%7Eopen` kept pathname `.../%7Eopen/standup`. `%257Eopen` stayed `%257Eopen`. This run does not show the URL constructor collapsing either spelling to `~`. Neither encoded dial posted `moq-connected` or an error before the 15 second wait. The native `wt-session` refusals remain the encoded-path admission evidence.

### HTTP mint, today's code

`path-mint-http.log`. `mix compile` does not build `Mjolnir.API.Router`: `authorize_app/4`, `authorize_deploy/3`, and `authorize_record/3` are undefined in this dirty tree. The product route was not served. A spike `Bandit` 1.14.1 plug called `Mjolnir.Relay.Mint.issue/5`.

- Body `{}`, `{"kind":"open"}`, and `{"kind":"protected"}` are HTTP 200. Response keys are `expires`, `publish`, `relay_host`, `root`, `subscribe`, `token`. There is no `kind`. Root is `t/<owner>/standup`. Claim names are `exp`, `iat`, `jti`, `publish`, `root`, `subscribe`. That is the old-mint fixture.
- Room `~open`: HTTP 400 `bad_segment`, `room_param` `~open`.
- Request target `%7Eopen`: Bandit decoded it. `request_path` and `room_param` are `~open`. HTTP 400 `bad_segment`. Same string as the literal tilde after one decode.
- Request target `%257Eopen`: one decode leaves `room_param` `%257Eopen` and `request_path` `/rooms/%257Eopen/...`. HTTP 400 `bad_segment`. It is not the tilde.

## Still open

- Production admission, and a repeat of these rows with a token from the future open mint. That mint is not written.
- An Iroh cross-root `unroutable` (or any other refusal string). The bounded result is a wait.
- A browser error string for the encoded WebTransport URLs. The pathname observation is separate from admission.
- The product HTTP route, until `Mjolnir.API.Router` compiles.
