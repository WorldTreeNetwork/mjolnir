# Acceptance notes — add-edge-relay

Laptop: Framework5070, `dorje@192.168.0.108`. Throwaway certificates. No production host.

## Automated

`cargo test --offline -- --test-threads=1` in `native/mjolnir_relay` on that laptop:

- `tests::group_writable_key_file_is_refused` — passed. A mode `0664` file is refused.
- `tests::refuses_missing_expiry_bad_owner_ticket_and_other_key` — passed. Covers a valid token, no token, a non-tenant path (the ticket stand-in), an HS256 header, a token signed by a key that is not in the set, a root `t/not-an-owner/a`, an expired token, no expiry, no issue time, a lifetime over the max, and a sibling prefix.
- `tokenless_webtransport_is_refused_and_sigterm_stops_a_second_session` — passed. A WebTransport session with no token is refused. After the drain flag is set, a second session with a valid token is refused. This sets the flag in-process. It does not send SIGTERM.

Counts: 2 library tests passed, 1 integration test passed, 0 failed.

## Commands and output

Name match, the check `relay-copy-cert.sh` uses:

```
Hostname relay.test does NOT match certificate
SUFFIX-REFUSED
Hostname relay.test does match certificate
EXACT-ACCEPTED
```

`relay-copy-cert.sh` against a destination whose parent is not root-owned:

```
relay-copy-cert: not root-owned: /tmp/tmp.…
```

A symlink component:

```
relay-copy-cert: symlink: …/linked
```

The positive copy into that `/tmp` tree did not run. The parent is not root-owned, so the script stopped before writing a key.

SIGTERM, debug binary, bind `127.0.0.1:24443`, drain 1 second, root-owned verify set:

```
listening=1 pid=3903059
sigterm_still_running=0
```

No session was held across that signal.

QUIC certificate, `openssl s_client -connect 127.0.0.1:24444 -quic -alpn h3`:

```
BEFORE= 0 s:CN=first
AFTER= 0 s:CN=second
```

The pair on disk was replaced between the two handshakes. The process was not restarted. A new session saw the new certificate. The earlier curl of `/certificate.sha256` never reached an HTTP listener, so it was not evidence about reload.

## Laptop proofs, 2026-11-21

Host `dorje@192.168.0.108` through the ssh wrapper. Throwaway name `relay.test` in `/etc/hosts` as `127.0.0.1`. `mjolnir` stayed MainPID `3621414`. There is no running `mjolnir-gateway` unit (`inactive`, MainPID 0), so the pid check is the controller only. No `mj-publish` rules were present, so none were changed.

`deploy.sh root@fw --relay` with no `/etc/mjolnir/relay.env`: exit 0. `mjolnir-relay` inactive, no unit file, no `mjolnir-relay` iptables rule, `/usr/local/bin/mjolnir-relay` absent.

First enable, after `relay.env` set `MJOLNIR_RELAY_ENABLED=true` and `MJOLNIR_RELAY_HOST=relay.test`, and `relay-copy-cert.sh` installed generation 1: exit 0. Unit `active`. Exactly one INPUT rule `-A INPUT -p udp -m udp --dport 443 -m comment --comment mjolnir-relay -j ACCEPT`. Controller pid unchanged. Journal: `listening addr=0.0.0.0:443` and `iroh endpoint: a98b9d88a8ab010381624170312c8398db7dda4b13407563eb861b9b5a6c4280`.

No certificate (symlinks moved aside), `deploy.sh --relay`: exit 1. Process log `cert.pem: No such file or directory`. Rule absent. After the restart limit, `is-failed` = `failed`, `Result=start-limit-hit`, `NRestarts=5`.

UDP 443 held by a root `python3` socket, `systemctl reset-failed`, `deploy.sh --relay`: exit 1. Journal: `failed to bind UDP socket` / `Address already in use (os error 98)`. The python pid was still alive. No rule.

Enabled then `MJOLNIR_RELAY_ENABLED=false` and `deploy.sh --relay`: exit 0. `No files found for mjolnir-relay.service`, inactive, rule none, `ss` showed no `mjolnir-relay` sockets (UDP 443 and the Iroh sockets closed). Second `deploy.sh --relay`: exit 0, still inactive, rule none.

Certificate reload, unit not restarted. `openssl s_client -connect 127.0.0.1:443 -servername relay.test -quic -alpn h3`:

```
BEFORE=subject=CN=relay.test
HOLD_OUT=held
relay-copy-cert: current -> gen-20261121T070934Z-3944499
AFTER=subject=CN=second
HOLD_STILL=3944402
moq_tokio::tls: reloading server certificates
HOLD_END=held
released
```

`current` was generation 1 (`CN=relay.test`) and then generation 2 (`CN=second`). The hold process was alive after the rename and later printed `released`.

Stop during a call. `wt-session hold` printed `held`, then `systemctl stop mjolnir-relay`. Journal: `shutdown requested; draining sessions window=8s`, `relay shutting down; draining session`, then `drain ended with every session gone; exiting elapsed=1.988990727s`. A new session one second later: `refused: failed to connect` / `Connection refused`. The unit was `inactive`.

Keys, same pid `3948555`:

```
active=f4d359cec65f7f2db2d3ff6785de273c07033f9cb934499168733cc0b0f7ea03
sha=f4d359cec65f7f2db2d3ff6785de273c07033f9cb934499168733cc0b0f7ea03
old_token_after_key_removed: refused: unauthorized
active_malformed=invalid
previously_valid_after_malformed: refused: app code=502
```

Missing key file at start: `Error: No such file or directory`, status 1. A PEM private key in the key file at start: `key file: invalid number at line 1 column 2`, status 1.

Mismatched pair: `relay-copy-cert: key does not match the leaf`, exit 1, `current` unchanged (`gen-20261121T070934Z-3944499`). Copy into `/tmp`: `group-writable: /tmp`, exit 1. Modes: tls dir `750 root:mjolnir-relay`, key `640 root:mjolnir-relay`. `nobody` could not read the destination or source key. `mjolnir-relay` could read the destination key and could not read the source key (`600 root:root`).

Expired certificate while running: `certificate is no longer usable`, then restarts, then `is-failed=failed`, `Result=start-limit-hit`.

Tokens, client `native/mjolnir_relay/examples/wt-session.rs` (`irl` has no token flag):

```
no-token: refused: unauthorized
login-jwt-hs256 (alg HS256): refused: unauthorized
journal: err=no token ; err=symmetric signature ; err=token refused
wrong-tenant t/not-an-owner/a: refused: unauthorized
ticket-path not-a-tenant: refused: unauthorized
ten-second token: session accepted 07:12:47, lease ended, closing session why=expired 07:12:55
```

A token signed by a second fixture key that was not installed: `refused: unauthorized`.

## Media through the relay, 2026-11-21

Clients: `examples/dev-key.rs`, `examples/iroh-publish.rs`, `examples/iroh-subscribe.rs`, `examples/wt-session.rs`. Owner `t/US517G5965aydkZ46HS38QLi7UQiSojurfbQfKCELFx`. Second tenant `t/YMN9Qj5jPNp7j14VPcML1B6xGgcPWVZUGLFU3Mnyfaf`. Relay endpoint `a98b9d88a8ab010381624170312c8398db7dda4b13407563eb861b9b5a6c4280` after the N0 bind. The Iroh path is the absolute `t/<owner>/a/b`. A WebTransport subscriber rooted at that owner sees `a/b`.

Iroh publisher, wide token, then WebTransport `wt-session read`:

```
published path=t/US517G5965aydkZ46HS38QLi7UQiSojurfbQfKCELFx/a/b bytes=1900
received path=a/b frames=41 bytes=779
```

Same publisher shape, Iroh subscriber:

```
received path=t/US517G5965aydkZ46HS38QLi7UQiSojurfbQfKCELFx/a/b frames=41 bytes=779
```

No token, including a session path equal to the client's own endpoint id:

```
notoken path=/ connected=false status=Reconnecting
refused
notoken path=<client endpoint id> connected=false status=Reconnecting
refused
```

Journal for the own-id dial: `the policy rejected the iroh client reason="ticket path"`.

Subscribe-only token, trusted key. Iroh `listen` and `publish`: `refused: relay link not connected`. WebTransport `publish`: `Error: unauthorized`. An Iroh session whose token has an empty publish set does not finish the handshake (`Handshake dropped without ok() or close()`). `origin.scope` rejects an empty pattern set, so a subscribe-only Iroh client cannot attach. WebTransport still accepts a subscribe-only token for announce and refuses the publish.

Narrow grant, publish pattern `a/b` and subscribe pattern `a/b`. Iroh publish connected and wrote the absolute path. WebTransport subscriber with `a/**` was told `prefix: Path("a/b")`. Subscriber with `z/**` printed no announcement. A later read of `a/b` on `a/**` saw no frames because the publisher had already released.

Two tenants. Owner 2 published `cam`. Owner 1's `**` subscribe printed nothing. Owner 2's subscribe printed `prefix: Path("cam")` and then the end of that route.

Sibling and `..`, while `a/b` was live. A read of `a/bx` printed `no-announcement` for that path. A read of `../a/b` also printed `no-announcement`. A WebTransport URL whose path is `t/<owner>x` was `refused: unauthorized` (`ticket path`). A URL path of `..` was `admitted`: the client URL parser resolves `..` before the relay sees it, so the request path is empty. That empty path is the session root, not a traversal.

Private JWK at start: `Error: /etc/mjolnir/relay-keys.json: key file holds a private key`. Symmetric JWK at start: `key file is not a public verify set: OCT key cannot be converted to public key`. The unit did not stay active.

Stop during the wide Iroh-to-WebTransport session. `systemctl stop` was issued at 07:55:07 and returned at 07:55:22. The reader got `frames=91 bytes=1729` and the publisher had been connected the whole time. The process then logged `shutdown requested; draining sessions window=15s`, `relay shutting down; draining session`, and `drain ended with every session gone; exiting elapsed=1.415488ms`. The 15 seconds were the wait before MoQ was told to stop, and the reader kept receiving through that wait. The session was closed when shutdown was requested, so MoQ's own drain did not run for another 15 seconds. The earlier two-second elapsed time was that same MoQ line when no session was left to drain.

Certificate generation swap during that same kind of session, same pid `4039793`:

```
BEFORE=subject=CN=relay.test
relay-copy-cert: current -> gen-20261121T075548Z-4040021
AFTER=subject=CN=second
received path=a/b frames=55 bytes=1045
moq_tokio::tls: reloading server certificates
```

Laptop cleanup. `MJOLNIR_RELAY_ENABLED=false` and `deploy.sh root@fw --relay` exited 0. The unit file is gone (`not-found`), the `mjolnir-relay` rule is gone, and `ss` shows no UDP 443 and no `mjolnir-relay` socket. A leftover `failed` state from the private-key restart loop cleared with `systemctl reset-failed`; `is-active` is then `inactive`. Controller pid stayed `3621414`. Left in place: user `mjolnir-relay`, `/var/lib/mjolnir-relay/tls`, `/etc/mjolnir/relay-keys.json`, `/etc/mjolnir/relay.env`, the `relay.test` hosts line, and `/tmp/relay-media`. No relay process and no example client is running.

## Still not run on this laptop

- `irl publish --relay` and a browser or `hang` viewer. `irl` cannot present a token. The Rust client held a WebTransport session and subscribed (`announce` printed no routes because nothing was publishing). It did not deliver media, so the narrow-grant and announcement-limit scenarios were not observed.
- An Iroh reader. The unit prints an endpoint id and opens its UDP sockets. No Iroh dial was completed.
- A real ACME order through `relay-issue.sh`, and the real-name journey. Those stay on production.
`deploy.sh --gateway` after `MJOLNIR_RELAY_ENABLED=false`, relay already running as pid `3963169`: the gateway build finished and the deploy exited 1 because `/etc/mjolnir/gateway.toml` is absent. It did not reach `systemctl restart mjolnir-gateway`. Afterwards the relay was still `active` pid `3963169`, the controller was still `3621414`, and the `mjolnir-relay` rule was still present. `--app-only` was not used because it bounces the controller and the VMs. The laptop has no `mjolnir-gateway` unit.

## Production, real name (2026-11-22)

Host `45.76.77.97`, name `media-relay.worldtree.network`, commit `3dd4df9`. Certificate from `relay-issue.sh` over HTTP-01, `not_after` 2027-02-20. Relay endpoint `b7d78d9972a0c9532613a770b0bb8e25bde740e6d1f9f2ee7fc58bdf19c1eb3f`. Clients ran on a Mac behind a home NAT. `wt-session` ran with `WT_VERIFY=1`, which checks the certificate against the public roots.

First enable on a clean host. The disabled deploy installed the scripts only. `relay-issue.sh` issued, then its copy failed: `install: invalid group 'mjolnir-relay'`. Fixed in `3dd4df9`: the disabled deploy creates the user, and the enabled deploy copies an issued pair before the unit starts. The enabled deploy then moved `relay.env` and `relay-keys.json` from `/etc/mjolnir` to `/etc/mjolnir-relay` (root:root `0755`) and started the unit. That host has no Node; the build needs none since `iroh-live-relay` was dropped.

Runbook checks: unit `active`, `mjolnir-relay-renew.timer` `enabled`, `keys.active` non-empty, one `INPUT` rule `udp --dport 443 --comment mjolnir-relay`, `0.0.0.0:443` held by `mjolnir-relay`. Controller pid 1160 before and after.

```
no token, WebTransport:            refused: unauthorized
Iroh publisher -> WebTransport:    received path=call/a frames=40 bytes=760
Iroh publisher -> Iroh subscriber: received path=t/4vJ9…LKi/call/a frames=30 bytes=570
subscribe-only token publishing:   Error: unauthorized
other tenant, path ../<owner>/call/a: frames=0 bytes=0 no-announcement
```

Gateway restart during a call. Publisher on Iroh for 40 s, WebTransport reader for 25 s, `systemctl restart mjolnir-gateway` 8 s in. Gateway pid 1227 -> 416551. Relay pid 415416 both sides. Reader: `received path=call/g frames=120 bytes=2280`. Publisher: `bytes=3762`. The API answered on HTTPS after the restart.

Not proven here: a real browser reading through this name (no page exists until `browser-call-client`), the laptop rerun of the suite at `3dd4df9` (laptop unreachable; the suite passed on macOS), and renewal by the timer against the real issuer.

## Iroh expiry (2026-11-22, macOS, not deployed)

Defect on the relay that is live at `3dd4df9`. `TokenPolicy::decide` returned `ext_grant(&grant).into()`, and `From<Grant> for Authorization` in moq-ext-access sets `expires: None`. `expiry()` in `iroh_sessions.rs` then waits forever. The ten-second-token note above is WebTransport only.

`tests/iroh_expiry.rs` (`iroh_session_closes_when_the_token_expires`) failed first: after the session reached `Connected` on a ten-second token, it was still `Connected` when the fifteen-second wait ended. The fix sets `Authorization.expires` from the token's `exp`. The same test then passed in 9.8 seconds. Full crate suite on this Mac: 3 lib tests, `iroh_expiry`, `webtransport`.

In-band WebTransport, review S3. `web_grant(true, …)` admitted the second token. The assertion failed with `in-band token was admitted`. The decider now returns `in-band token` and the test passes. A refresh that uses that path is a contract question, not this fix.

`iroh-subscribe read` does not stop at its seconds when its path is never announced. The other-tenant check above used `wt-session` for that reason.
