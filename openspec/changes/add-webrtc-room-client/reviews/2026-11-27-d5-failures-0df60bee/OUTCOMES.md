# D5 same-path failures on 0df60bee

Evidence only. Page and gateway binaries were not edited. Served hashes match `0df60bee`: boot.js `07350c81…bbe31`, room.js `532c2de9…93cb`. Gateway binaries are the accepted edge `57a21527…` and relay `9c24f67c…`.

The init-script hook is labeled `labeled D5: body reject, bad answer, or stalled publisher connectionState`. `body` makes the next WHIP `201` body reject. `sdp` replaces that body with `not-an-sdp`. `ice` reports `connectionState` as `connecting` on the next publisher PC until the page's own 10 s wait finishes, then the page closes that PC. Subscribers are not hooked. Waits are 20 s, 20 s, and 25 s for the publisher result, then 12 s of tile samples.

Alice publishes `alice/cam`. Bob is already playing that path. Carol clicks Join in the same turn as Alice's Replace.

| mode | publisher result | incumbent | candidate PC | Bob | Carol |
| --- | --- | --- | --- | --- | --- |
| body | `The room could not be connected.` in 202 ms | id 1, 2 open PCs, 2 live local tracks, same two session paths | third PC, the new publisher, closed | stayed owner `1:1`, `Playing.`, 439 Hz, rms 0.0095 | joined owner `1:1`, one `Waiting` frame at width 0, then `Playing.`, 439 Hz |
| sdp | same sentence in 204 ms | same shape | new publisher PC closed | same as body | same as body |
| ice | same sentence in 10296 ms | same shape; stalled publisher PC closed | closed after the timeout | stayed owner `1:1`, `Playing.`, 439 Hz | owner `1:1` then a real detach (`srcObject` false, caption `Waiting`) at about 5.6 s, then owner `1:2`, `Playing.`, 439 Hz |

No sample had caption `Playing.` with a missing stream, width 0, or an ended track. Page errors were empty.

The edge log accepted a second `alice/cam` publish on every attempt (`cap=2500000`) before the page failed the candidate. That is the non-atomic pin. Body and SDP failures did not move Bob or Carol off the still-live incumbent media. The ICE attempt did move Carol: the replacement was announced, her first subscription became unroutable, and a later subscription on the same generation recovered tone. Bob's already-connected subscription stayed on its original tracks. This is not a seamless rollback, and none is claimed.

Incumbent session lists did not gain a third path. The candidate publisher PC was closed in every case. This edge log level does not print the HTTP DELETE.

## Release inventory for this local slice

Done locally, and not a campaign close:

- Named-peer page on the accepted gateway, including sustained 439 Hz and the known frame colors after replace and renew (`reviews/2026-11-27-tone-0df60bee/`, `f2322149`).
- Held WHIP `201` plus Leave clears tiles and does not restore `Playing.`.
- This D5 failure matrix.

Still owed before `.15` or the node can close:

- `.14` roster.
- Safari on a phone.
- Three networks.
- Eight PeerConnections.
- Upstream packaging.

`.15` stays open.
