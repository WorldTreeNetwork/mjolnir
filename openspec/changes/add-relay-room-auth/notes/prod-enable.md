# Production enable (2026-11-23)

Host `45.76.77.97`, name `media-relay.worldtree.network`. Run by the orchestrator, not the builder. Duke approved the controller cutover and the key install on 2026-11-23.

## Order

1. `deploy.sh root@45.76.77.97 --app-only`. Controller release `4d2e599`, cutover verified by `release_control.py` (guest processes and agents unchanged). Before any key: unauthenticated mint `401`, operator socket `403`.
2. `deploy.sh --relay`. Built in 6m01s on the warm cache. The guard refused the install: `key file holds a key with no kid`. The running relay and `/usr/local/bin/mjolnir-relay` were left alone.
3. The printed command, `RELAY_BIN=<staged> <staged>/scripts/relay-mint-key.sh`. Output `first install confirmed mQ6GXa6wAxDdZxbWbQxSwQ`, exit 0. The old relay process (`105acf0`) picked the new set up on its key poll with no restart. `current.jwk` is `0600 root`, directory `0700`.
4. `deploy.sh --relay` again. Guard passed, relay restarted at 19:10:08 UTC, same Iroh endpoint id `b7d78d99…eb3f`.

The fixture key file was copied to `/root/relay-keys.fixture-backup.json` first. It holds a public key only.

## Room test

Clients on a Mac behind NAT. Every token came from `POST https://api.vm.worldtree.network/api/relay/rooms/<room>/participants/<name>/token` with a real user session. Owner in the root was the caller's verified id, `t/3dLGACrVKP67MtW4kwbG54JqBGS5nSb46uZVkJNueWKJ/<room>`. Default life 3600 s. Script and output: orchestrator scratchpad `prod-room-test.sh`, `prod-room-test.log`.

| Check | Result |
| --- | --- |
| No token | `refused: unauthorized` |
| alice publishes over Iroh, bob reads over WebTransport | 40 frames, 760 bytes |
| same, bob reads over Iroh | 31 frames, 589 bytes |
| Token for another room, reading `alice/cam` under its own root | no announcement, 0 frames |
| Token for another room on this room's URL | `refused: unauthorized` |
| bob publishes `alice/fake` | alice's reader saw no announcement |
| bob publishes `bob/cam` | alice read 15 frames |
| Token signed by the old fixture key | `refused: unauthorized` |
| `ttl: 10` token, Iroh publisher | journal: admitted 19:10:58.09, `the iroh client's authorization expired, closing its session` 19:11:07.00 |

The example publisher keeps writing locally after the relay closes it, so its own byte count and run time do not show the close. The journal line is the evidence.

## Not run on production

- Rotation, `finish`, and `emergency`. Laptop only (`laptop-rotation.md`).
- A second tenant. Both rooms above belong to one owner. Cross-tenant refusal is covered by the relay's unit tests and the edge-relay production run.
- A browser.
