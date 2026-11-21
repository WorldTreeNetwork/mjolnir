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
the leaf, then renames `current`. If the unit is active, the script
restarts it. A renewal ends calls. That is about every 60 days.

## Disable

Set `MJOLNIR_RELAY_ENABLED=false` and run `deploy.sh --relay` again.
The unit and the tagged rule are removed. Another deploy does not
touch them.
