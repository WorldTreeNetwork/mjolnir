# Edge relay

`mjolnir-relay` serves WebTransport on UDP 443. It is off by default.
The production hostname and the switch that turns it on are Duke's.

## Enable

1. Issue a certificate for the relay name into a directory mode `0700`
   owned by the issuer, holding no other subject. `issue_http01` accepts
   a name that is not an app domain. `POST /api/certs/issue` does not.
2. Put the public verify JWKs at `/etc/mjolnir/relay-keys.json`, mode
   `0644`, root-owned. Public keys only. EdDSA or ES256.
3. In `/etc/mjolnir/relay.env` (root-owned, mode `0640`, not the
   controller's `/etc/mjolnir/env`) set `MJOLNIR_RELAY_ENABLED=true`,
   `MJOLNIR_RELAY_HOST`, and `MJOLNIR_RELAY_ACME_EMAIL`.
   Issue with `scripts/relay-issue.sh <host> <email>`. That is not
   `POST /api/certs/issue`. The daily cert timer calls
   `scripts/relay-renew.sh`, which no-ops when the relay file has no host.
4. `./scripts/deploy.sh <host> --relay`

The firewall rule is added only after the unit is active. Its comment
is `mjolnir-relay`.

## Certificate copy

```bash
sudo scripts/relay-copy-cert.sh /path/cert.pem /path/key.pem "$MJOLNIR_RELAY_HOST"
```

The copy checks the path, the name, the dates, and that the key matches
the leaf, then renames `current` and points `cert.pem` and `key.pem` in
that directory at `current/`. The process opens those two links. A
running relay serves the new pair to sessions opened after that rename.
It is not restarted.

## How to run the acceptance

The example clients live in `native/mjolnir_relay/examples/`. They are not installed. On a Linux host, from that crate:

```bash
cargo build --release --examples
```

- `dev-key public` prints a public verify set. `dev-key owner <byte>` prints `t/<id>`. `dev-key tokens <seconds> <name> <root> <publish> <subscribe> ...` prints one `SET` line and one `TOKEN` line per token. Patterns are comma-separated. `-` is an empty list. `dev-key private-jwk` and `dev-key oct-jwk` print key files that must not be installed.
- `iroh-publish publish <relay-id> <token> <absolute-path> <seconds>` attaches with `RelayConfig::iroh` and `with_token`, and writes a `bytes` track. The path is the absolute tenant path, `t/<owner>/...`, because the Iroh grant is rooted there. `iroh-publish notoken <relay-id> [self]` dials with no token. `self` uses the client's own endpoint id as the session path.
- `iroh-subscribe read <relay-id> <token> <absolute-path> <seconds>` prints frames and bytes. `iroh-subscribe listen` prints announcements.
- `wt-session publish` and `wt-session read` do the same over WebTransport. The URL carries `?jwt=`. The path is relative to the token root, so an absolute `t/<owner>/a/b` is read as `a/b`. `wt-session refuse` expects the session to be refused.

Install the `SET` line as `/etc/mjolnir/relay-keys.json` before using the tokens. The relay endpoint id is the `iroh endpoint:` line in the journal.

## Disable

Set `MJOLNIR_RELAY_ENABLED=false` and run `deploy.sh --relay` again.
The unit and the tagged rule are removed. Another deploy does not
touch them.
