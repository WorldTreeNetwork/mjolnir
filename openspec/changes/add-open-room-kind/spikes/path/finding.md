# Path-marker spike (2026-11-26)

Local harness only. Dummy EdDSA key `spike-kind`, generated in the process. Pinned moq `4a6f52248` via the relay crate's lock. The relay process is `open-room-kind-spike relay`: production `spawn_web_decider` and `TokenPolicy`, not the claim route. Certificate is a 10-day self-signed ECDSA P-256 leaf. No production host, no production key.

Logs: `../logs/path-offline.log`, `../logs/path-live.log`, `../logs/path-live-extra.log`. Script: `live.sh`.

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

## What this does not show

- Production admission.
- A full Iroh own-read and cross-read pair with frames or a clean refusal on both sides.
- A browser MoQ publish that a second MoQ client reads.
- The controller mint, because that code is not written and the tree did not compile.
