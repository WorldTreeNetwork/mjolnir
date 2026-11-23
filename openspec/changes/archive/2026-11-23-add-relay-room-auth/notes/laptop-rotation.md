# Laptop rotation, 2026-11-22

Host `dorje@192.168.0.108` (Framework5070). Binary `/usr/local/bin/mjolnir-relay` from release `d4d5443`. Script copied to `/tmp/relay-mint-key.sh` at `3142746` after the public-sidecar fix. Relay env drain is 15s. No production host was touched.

The deploy of `d4d5443` built the relay and installed the unit, then the unit failed: `key file holds a key with no kid`. The fixture public key had `kid` null. `systemctl stop` ended the restart loop. `/opt/mjolnir` stayed on `c47f35ee` because the deploy exited before cutover.

## Before and after

| Case | Before | After |
|---|---|---|
| Loader, no `kid` | `a key with no kid was accepted` | `loader_rejects_a_key_with_no_kid` passed |
| Loader, ES384 | `ES384 was accepted` | `loader_rejects_a_disallowed_algorithm` passed |
| First install, relay down | fixture kid null, no `current.jwk` | exit 1, public kid `UPeSozrTGsutFBf9Gb3CCA`, `current.jwk` absent |
| First install, relay up | same public set, relay active | `first install confirmed UPeSozrTGsutFBf9Gb3CCA`, `current.jwk` written |
| `kid` containing `:` | hashes of the public set and `current.jwk` recorded | `kid refused before publish: bad:kid` (script exited before the hash compare; the compare on the next command matched) |
| Malformed `.pub` (`alg` none) | same two hashes | exit 1, `candidate rolled back; signer unchanged`, hashes unchanged, `next.jwk` removed |
| Second rotate during overlap | `rotation.json` present | exit 1, `an overlap is unfinished; the oldest public key stays` |
| `finish` after `not_before` set to 0 | two-key overlap | `public set is 9EmX5wlBoJA2E2aHa_ci_Q only` |
| Live session across routine rotate | `wt-session hold` printed `held` | rotate exit 0, signer `LyKgIXB5Clh9C7A66VdlXw`, client printed `released`, exit 0 |
| Emergency | session `held` on the old key | script printed the 15s drain twice, `emergency signer is u_ynO6A6Sj-Izh_tHGiWrA`, exit 0. Journal: shutdown requested, session error, `drain ended with every session gone` in 1.37ms. A later `wt-session refuse` with the old token printed `refused: unauthorized` |
| Mint route | — | `POST /api/relay/rooms/standup/participants/alice/token` returned 401 with no user token |

This note stops at the rotation table above. Later the same day, a user mint, both-transport acceptance, the in-band client test, and the hole measurement were run and written down in `notes/h-handoff.md` and in `tasks.md`. The crash points and the failed-confirmation restore are covered by `scripts/relay-mint-key-test.sh`.
