# Edge relay

Drafted by Fable 5.2 (blast: protocol, authorisation, public listener).

## Current

- The gateway (`native/mjolnir_gateway`) is TCP only: HTTP/1 on 80 and 443, rustls on `ring`, `iroh = "1.0"`. It issues certificates by HTTP-01 and hot-swaps them on SIGHUP (`tls.rs`).
- Nothing on a Mjolnir host listens on UDP 443.
- `iroh-live-relay` at `747b1bd` is a library and a binary. Its `run` sets `listen.tls.generate = ["localhost"]` and takes no certificate. It exports `admit`, `IrohSessions`, `pull::Pulls`, `relay_policy` and `KeyFile` "for a binary that embeds the relay with a moq-relay of its own".
- `moq_tokio`'s server TLS takes `cert` and `key` path lists.
- The exported `admit` gives a browser with no token subscribe rights everywhere. `IrohSessions::with_policy` replaces the rule for Iroh clients.
- iroh-live pins `iroh 1.4.1` on `aws-lc-rs` and moq by git revision. It is not on crates.io and says to expect API changes.

## Decisions

**D1. Own process.** `mjolnir-relay` is a host service with its own unit and its own user. Not in the gateway: a gateway deploy must not end calls, and a draft-protocol parser should not share a process with every site's TLS. Not in a guest: the service needs the host's name, certificate and UDP 443, and a tenant guest must not hold that key.

**D2. Compose, do not call `run`.** The crate builds its own `moq_relay::Config` and reuses `IrohSessions`, `KeyFile` and the cluster from iroh-live-relay. It writes its own browser admission loop over `moq_relay`'s `Admissions`. iroh-live is a git dependency at one pinned revision. Moving the pin is a change with its own acceptance run.

**D3. One listener.** WebTransport over HTTP/3 on UDP 443 at `:relay_host`. The relay serves no web page and binds no TCP port. The viewer page is someone else's to host.

**D4. Certificate from the gateway's issuer, copied by root.** `:relay_host` is one more HTTP-01 subject and nothing else: no `[[domain]]`, no route, no public issuance or listing. The issuer runs as `mjolnir`; today `acme.rs` writes the chain and key as two separate replaces and tightens the key's mode afterwards. So the relay never reads the gateway's files. A root step copies the one pair into a new generation directory under `/var/lib/mjolnir-relay/tls/`, created private before any key byte lands, checks that the key matches, the name matches and the dates are good, then swaps `current` by one rename. On failure `current` stays. The relay refuses to start without a good pair, never generates one, and exits when the one it serves expires.

**D5. Deny by default, one token profile.** A browser or Iroh session with no token, a bad token, or a token whose grant does not cover the path is refused. There is no public path and an Iroh endpoint id grants nothing. Tokens are moq-auth JWTs at the pinned revision. That format has `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf` and `jti`, refuses unknown fields and ignores `iss`, so it cannot carry an audience. Purpose is bound by the key instead: the relay key file holds public keys whose private halves sign relay tokens and nothing else, and the relay holds no private key. EdDSA and ES256 only. Our admission adds what moq-auth leaves optional: an expiry, an issue time, a bounded lifetime, and a root under `t/<owner id>`. The session closes at expiry.

**D5a. Keys fail closed.** The key file is root-owned and replaced by rename. A bad file at start stops the unit. A bad file at reload refuses all new sessions. The relay writes the active file's hash, or `invalid`, to `/run/mjolnir-relay/keys.active`, so whoever rotated a key can see that it took. Retaining the old set on a bad reload was rejected: a revocation would then fail silently.

**D6. Tenant-rooted paths.** Every broadcast lives under `t/<owner id>/`. `<owner id>` is the canonical base58 id Mjolnir already uses as `owner_id`. What sits below that prefix is `add-relay-room-auth`'s to define. This change only fixes the prefix, so limits and metering can key on the second path segment.

**D7. No pulls.** The relay never dials an Iroh endpoint because a session named a ticket. Publishers push over a relay link. That removes the one way a client could make the host open connections of the client's choosing.

**D8. One owner of the relay's state.** `deploy.sh --relay` installs, updates, enables, disables and removes the unit and its one firewall rule (UDP 443 input, tagged `mjolnir-relay`), reading `:relay_enabled` and `:relay_host`. No other deploy touches either, in either direction. The rule is added only after the unit is active. On SIGTERM the relay refuses new sessions on both transports, waits up to `:relay_drain_seconds`, closes the rest and exits.

**D9. Off by default.** `:relay_enabled` false. Then no unit, no listener, no firewall change.

## What the host can see

The relay terminates QUIC. Whoever runs the host can read the media of every call that passes through it. Peer-to-peer Iroh calls do not have this property. moq has an `moq-e2ee` crate; using it is not in this change.

## Unverified hypotheses

- **relay-deps.** A crate on `iroh 1.4` + `aws-lc-rs` builds in `native/` beside the gateway on `iroh 1.0` + `ring`. Confidence: medium. Verification: `cargo build -p mjolnir-relay` on the Framework laptop, then `cargo build -p mjolnir-gateway` and its tests. If it fails: the relay becomes its own cargo workspace under `native/mjolnir_relay`.
- **relay-no-http.** `moq_relay::Relay` runs with `web.http.listen` unset and still serves WebTransport. Confidence: medium. Verification: start it that way, connect with the stock viewer. If it fails: bind the HTTP listener to loopback.
- **relay-admission.** Our loop over `Admissions` sees the token a browser sends (`?jwt=` or SETUP) and can refuse before any subscribe. Confidence: medium. Verification: a tokenless browser session against the built relay gets a refusal and no catalog. If it fails: use `auth.url` against a loopback endpoint of our own.
- **relay-cert-reload.** A renewed certificate is served without restart. Confidence: low. Verification: swap the pair, open a new session, read the served certificate. If it fails: the copy step restarts the unit, which drains first, and the ADR says a renewal ends calls roughly every 60 days.
- **cert-subject.** The gateway's issuer can hold a subject that is neither an app domain nor a site alias. Confidence: medium. Verification: read `site-certs` and `acme.rs`; issue against a staging directory. If it fails: this change adds a MODIFIED `site-certs` requirement and needs fresh advise.
- **viewer-https.** iroh-live's stock viewer, given an `https://` relay URL, connects without fetching `/certificate.sha256`. Confidence: medium. Verification: read the moq web client at the pinned revision; try it.

- **relay-expiry-close.** A WebTransport session is closed when its grant's expiry passes, as the docs say an Iroh session is. Confidence: medium. Verification: a ten-second token against the built relay. If it fails: our loop holds a timer per session and closes it.
- **relay-key-loader.** moq-auth's key types let us load a JWK set ourselves, reject symmetric and private keys, and swap the set used by both the browser loop and the Iroh policy. Confidence: medium. Verification: write the loader and the three key scenarios. If it fails: the relay restarts (draining) on a key change and the five-second bound becomes the drain bound.
- **relay-announce-scope.** Announcements to a session are filtered by its subscribe patterns. Confidence: medium. Verification: the announcements scenario. If it fails: one cluster origin per tenant.
- **relay-drain-both.** Admission can be stopped on WebTransport and on Iroh while existing sessions continue. Confidence: medium. Verification: the stop scenario.

## Where it is accepted

A real certificate needs a public name. The Framework laptop has none, so build and refusal tests run there with a throwaway certificate authority trusted by the test client, and the real-name journey runs on prod. Enabling it on prod is a human step.
