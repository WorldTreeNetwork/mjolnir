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

## Not run

- A live Iroh dial, and `irl publish` / `irl` play.
- `POST` issuance, a real ACME order, and `relay-issue.sh` against Let's Encrypt. The laptop has no public name.
- `deploy.sh --relay` lifecycle: never-enabled, first enable, failed enable, port held, disable, disable twice, another deploy, gateway restart during a call.
- `systemctl stop` while a session is playing.
- Root ownership of a key file. The test user cannot create a root-owned file and then stat it as the failure case inside `cargo test`. The group-writable case was run. The SIGTERM run did use a root-owned file and the process started, so that file passed the check.
