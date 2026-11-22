# Edge relay

`mjolnir-relay` serves WebTransport on UDP 443. It is off by default.
The production hostname and the switch that turns it on are Duke's.

## First enable on a host

Production name: `media-relay.worldtree.network`. The DNS A record is
DNS-only. This does not cut the controller release over. `/opt/mjolnir`
is not used.

1. On a build machine, from `native/mjolnir_relay`, create the signing
   key. The private file stays off the relay host (or anywhere the relay
   user cannot read). The command writes it mode `0600` and prints only
   the public set:

```bash
cd native/mjolnir_relay
cargo run --release --example dev-key -- generate "$HOME/relay-signing.json"
```

Save that stdout as `relay-keys.public.json`. Do not install
`relay-signing.json` as the verify file.

2. On the relay host, as root:

```bash
install -d -o root -g root -m 0755 /etc/mjolnir-relay
install -m 0640 -o root -g root /dev/null /etc/mjolnir-relay/relay.env
install -m 0644 -o root -g root relay-keys.public.json /etc/mjolnir-relay/relay-keys.json
```

`/etc/mjolnir-relay` is root:root mode `0755`. The gateway user must not
own it and must not be able to write it. A directory owner can replace
the key file. `/etc/mjolnir-relay/relay.env` is exactly:

```
MJOLNIR_RELAY_ENABLED=false
MJOLNIR_RELAY_HOST=media-relay.worldtree.network
MJOLNIR_RELAY_ACME_EMAIL=<the ACME account address>
MJOLNIR_RELAY_DRAIN_SECONDS=30
```

Put the real ACME account address in place of `<the ACME account address>`.
Use that same address in the issue command below. Leave `ENABLED` false
for this first deploy so the unit does not start before a certificate
exists.

3. From the repo, install the relay scripts without starting the unit.
   This also creates the system user `mjolnir-relay` and
   `/var/lib/mjolnir-relay/tls`, which the certificate copy needs.
   No unit is installed while `ENABLED` is false:

```bash
./scripts/deploy.sh root@45.76.77.97 --relay
```

4. Issue the certificate. This is not `POST /api/certs/issue`. Port 80
   on that name must reach this host for the HTTP-01 challenge.

```bash
ssh root@45.76.77.97 /usr/local/lib/mjolnir-relay/relay-issue.sh \
  media-relay.worldtree.network '<the ACME account address>'
```

If that certificate still has more than 30 days left, running the same
command again copies it and does not place another ACME order. A
certificate inside that window is issued again. The enabled deploy
below also copies `/var/lib/mjolnir/relay-acme/<host>/` before it
starts the unit.

5. Set `MJOLNIR_RELAY_ENABLED=true` in `/etc/mjolnir-relay/relay.env` and deploy
   again:

```bash
./scripts/deploy.sh root@45.76.77.97 --relay
```

6. Check, on the host:

```bash
systemctl is-active mjolnir-relay
systemctl is-enabled mjolnir-relay-renew.timer
test -s /run/mjolnir-relay/keys.active && echo keys.active
iptables -S INPUT | grep -- '--comment mjolnir-relay'
ss -ulpn | grep ':443'
```

`keys.active` is non-empty when the public set loaded. The iptables
line appears once: UDP dport 443, comment `mjolnir-relay`, inserted at
the top of `INPUT` (before ufw's chain, and also when ufw is not
installed). The unit adds that rule in `ExecStartPost` and removes it
in `ExecStopPost`, including after a failed start. A reboot starts the
enabled unit, which puts the rule back.

Renewal is `mjolnir-relay-renew.timer` →
`/usr/local/lib/mjolnir-relay/relay-renew.sh`. It does not call
`/opt/mjolnir`. A later token is signed with the private file from
step 1:

```bash
cargo run --release --example dev-key -- sign "$HOME/relay-signing.json" \
  3600 t/<owner> '**' '**'
```

## Enable

After the first enable, a later `./scripts/deploy.sh <host> --relay`
with `MJOLNIR_RELAY_ENABLED=true` and `MJOLNIR_RELAY_HOST` set reinstalls
the binary, the unit, and the scripts under `/usr/local/lib/mjolnir-relay/`.
The unit owns the firewall rule. The renew timer is enabled only after
the process is still active.

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

Install the `SET` line as `/etc/mjolnir-relay/relay-keys.json` before using the tokens. The relay endpoint id is the `iroh endpoint:` line in the journal.

## Room tokens

The controller mints a room token at

`POST /api/relay/rooms/:room/participants/:participant/token`

The caller is a user principal with `relay:join`. The owner is that
caller's `sub`. The private key is `/var/lib/mjolnir/relay-mint/current.jwk`
(mode `0600`, root). The public set the relay loads is
`/etc/mjolnir-relay/relay-keys.json`. The mint reads enabled, host, and
`MJOLNIR_RELAY_TOKEN_MAX_TTL` from `/etc/mjolnir-relay/relay.env` on
every call. A missing file, enabled other than `true`, or an unset host
is 503 and no signature. The response sends `Cache-Control: no-store`.

A removed participant who can mint again is back after the next token.
The default life is the ceiling: `MJOLNIR_RELAY_TOKEN_MAX_TTL`, or 3600
when that line is absent. A guest who was handed a token keeps it until
that token's own `exp`. There is no per-participant kick. A call longer
than one token needs the client to resubscribe when a participant
announces again.

## Rotation

`scripts/relay-mint-key.sh` as root. One lock,
`/var/lib/mjolnir/relay-mint/rotation.lock`.

- `relay-mint-key.sh` starts a routine rotation, or a first install when
  `current.jwk` is absent. First install publishes the new public key,
  waits until `/run/mjolnir-relay/keys.active` matches, and only then
  writes `current.jwk`. If the relay is down the new public set stays
  and `current.jwk` is not written. Run it again after the relay is up.
  That publish replaces a fixture key that has no `kid`.
- The first invocation writes `/var/lib/mjolnir/relay-mint/rotation.json`
  (mode `0600`) with the new `kid`, the time `finish` may run
  (`now + ceiling + 60`), and the hash of the two-key set. It switches
  `current.jwk` to the new key only after `keys.active` confirms that
  set. A second routine rotation while the overlap is unfinished exits
  non-zero and leaves the oldest public key in the set.
- `relay-mint-key.sh finish` drops the old public key. It refuses to do
  that before the time in `rotation.json`.

`mjolnir-relay --check-keys <path>` validates a candidate with the
relay's loader before the file is renamed into place. The loader
rejects a private key, a key with no `kid`, and an algorithm other than
EdDSA or ES256.

## Emergency revoke

`relay-mint-key.sh emergency` replaces the public set with one new key
and does not restore the previous set. It deletes `next.jwk` if a
routine rotation was in flight. At the moment the new public set is
published it removes `current.jwk` and `current.jwk.pub`, so the mint
returns 503 until a later run writes a signer the relay has confirmed.
It restarts the relay and exits non-zero when confirmation failed or
the restart failed. The new public set stays either way.

A failed or interrupted emergency is finished by the same default
command, which takes the first-install path and reuses `staged.jwk`:

```bash
RELAY_BIN=/usr/local/bin/mjolnir-relay /opt/mjolnir/scripts/relay-mint-key.sh
```

Use the staged binary from a refused deploy when the installed binary
is older than `--check-keys`. Do not pass `rotate` or `finish`. The
compromised kid is not in the new set.

A restart sends SIGTERM. The process drains for the
`MJOLNIR_RELAY_DRAIN_SECONDS` it loaded at start (default 30) and then
stops. The script prints that window. It does not shorten the drain. A
live session signed by the removed key stays up for that window. New
sessions fail at the one-second key poll, or at the restart if the
process was already down. The mint key is host-wide: it can sign a root
under any tenant.

## Disable

Set `MJOLNIR_RELAY_ENABLED=false` and run `deploy.sh --relay` again.
The relay unit, `mjolnir-relay-renew.timer`,
`mjolnir-relay-renew.service`, and the tagged rule are removed.
The scripts under `/usr/local/lib/mjolnir-relay/` stay, so a later
issue still runs without the controller release. Another deploy does
not start the unit.
