# ADR 0016 — Edge relay

**Status:** Accepted for implementation (2026-11-21). Not folded.
**Change:** [`add-edge-relay`](../../openspec/changes/add-edge-relay/proposal.md)
**Contract:** `d94e71e` ([`reviews/2026-11-21-advise-2.md`](../../openspec/changes/add-edge-relay/reviews/2026-11-21-advise-2.md))
**Full argument:** [`design.md`](../../openspec/changes/add-edge-relay/design.md)

## One screen

1. `mjolnir-relay` is its own host process and user. Not the gateway, not a guest.
2. It composes `moq_relay::Config` and its own Iroh session handler. It does not depend on `iroh-live-relay`.
3. One WebTransport listener, UDP 443, no TCP page. Pins: iroh-live `747b1bd`, moq `4a6f52248`.
4. `:relay_host` is only a certificate subject. Root copies the pair into `/var/lib/mjolnir-relay/tls/` by generation and rename. The relay never generates a certificate.
5. A renewal does not restart the unit. The process opens `tls/cert.pem` and `tls/key.pem`, which point at `current/`. Renaming `current` is the reload. A session opened before the rename stays up.
6. Deny by default. moq-auth JWTs, EdDSA or ES256, expiry required, root `t/<owner id>`. No ticket pulls.
7. `deploy.sh --relay` is the only operation that installs, starts, stops, or removes the unit and its one UDP 443 rule tagged `mjolnir-relay`.
8. `:relay_enabled` is false until Duke turns it on and names `:relay_host`. The host can read relayed media. End-to-end encryption is a later node.

## Decisions

D1–D9 in `design.md` stand. One decision changed during the spike:

**DECISION 2026-11-21:** a renewal does not restart `mjolnir-relay` — a QUIC handshake showed the new certificate after the files changed, with the previous session still up — replaces the restart-on-renewal decision.

**DECISION 2026-11-21:** the relay unit reads `/etc/mjolnir-relay/relay.env` only, and the public verify set is `/etc/mjolnir-relay/relay-keys.json`. That directory is root:root mode `0755`. `/etc/mjolnir` is owned by the gateway user, who could replace a file there. Replaces the decision that those files lived in `/etc/mjolnir`.

**DECISION 2026-11-21:** a path is refused unless it is under `t/<canonical owner id>/` — a ticket is not that path, and pulls stay off — replaces treating any single segment that does not start with `t` as a ticket.

**DECISION 2026-11-21:** the process opens `tls/cert.pem` and `tls/key.pem`, and moq watches that parent directory. Watching `current/cert.pem` follows the generation directory and misses a rename of `current`.

**DECISION 2026-11-21:** the Iroh endpoint uses the N0 preset and advertises the MoQ ALPNs before bind. A Minimal endpoint publishes no relay address, so a client that only has the endpoint id cannot dial it.

**DECISION 2026-11-21:** the Iroh session handler lives in `native/mjolnir_relay` (`iroh_sessions.rs`, from iroh-live `747b1bd`, MIT OR Apache-2.0). Pull code is not included. The relay does not depend on the `iroh-live-relay` crate, whose build fetches a web client.

**DECISION 2026-11-22:** room tokens are minted by the controller for a user principal, from `/var/lib/mjolnir/relay-mint/current.jwk`. The relay verifies `/etc/mjolnir-relay/relay-keys.json`. Rotation and emergency revoke are `scripts/relay-mint-key.sh`. Emergency revoke never puts the old public key back. A live session on a removed key lasts the drain loaded at process start (default 30 seconds). There is no control to shorten that drain. A removed participant who can mint again returns on the next token; a guest keeps the token until its own `exp`.

The relay package is its own Cargo project under `native/mjolnir_relay`. The gateway keeps `iroh 1.0` and `ring`. A throwaway workspace already linked `iroh 1.4` (`tls-aws-lc-rs`) beside `iroh 1.0`.

Browser tokens arrive as `?jwt=`. The admission loop reads that query and a SETUP token. `request.token` stayed empty for the browser form.

## Built vs remaining

Built with this ADR: the crate, refusal tests, the systemd unit, `deploy.sh --relay`, the root copy step, and the config keys. Off by default.

Remaining, and not this node: Duke enables the relay on production and picks the hostname. The real-name journey runs there. Room tokens, the browser client, and a self-hosted Iroh relay are later nodes.
