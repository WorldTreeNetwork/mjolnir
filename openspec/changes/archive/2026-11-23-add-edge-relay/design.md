# Edge relay

Drafted by Fable 5.2 (blast: protocol, authorisation, public listener).

## Current

- The gateway (`native/mjolnir_gateway`) is TCP only: HTTP/1 on 80 and 443, rustls on `ring`, `iroh = "1.0"`. It issues certificates by HTTP-01 and hot-swaps them on SIGHUP (`tls.rs`).
- Nothing on a Mjolnir host listens on UDP 443.
- The Iroh session handler is `native/mjolnir_relay/src/iroh_sessions.rs`, adapted from `iroh-live-relay` `747b1bd` (MIT OR Apache-2.0) with every pull path removed. The relay crate does not depend on `iroh-live-relay`.
- `moq_tokio`'s server TLS takes `cert` and `key` path lists.
- The exported `admit` gives a browser with no token subscribe rights everywhere. `IrohSessions::with_policy` replaces the rule for Iroh clients.
- iroh-live pins `iroh 1.4.1` on `aws-lc-rs` and moq by git revision. It is not on crates.io and says to expect API changes.

## Decisions

**D1. Own process.** `mjolnir-relay` is a host service with its own unit and its own user. Not in the gateway: a gateway deploy must not end calls, and a draft-protocol parser should not share a process with every site's TLS. Not in a guest: the service needs the host's name, certificate and UDP 443, and a tenant guest must not hold that key.

**D2. Compose, do not call `run`.** The crate builds its own `moq_relay::Config` and its own `IrohSessions`. It writes its own browser admission loop over `moq_relay`'s `Admissions`. `moq-transport-iroh` and `moq-ext-access` stay git dependencies at `747b1bd`. Moving that pin is a change with its own acceptance run.

**D3. One listener.** WebTransport over HTTP/3 on UDP 443 at `:relay_host`. The relay serves no web page and binds no TCP port. The viewer page is someone else's to host.

**D4. Certificate from the gateway's issuer, copied by root.** `:relay_host` is one more HTTP-01 subject and nothing else: no `[[domain]]`, no route, no public issuance or listing. The issuer runs as `mjolnir`; today `acme.rs` writes the chain and key as two separate replaces and tightens the key's mode afterwards. So the relay never reads the gateway's files, and for this subject the issuer writes into a directory of its own, private from the first byte (a restrictive umask and a 0700 directory holding no other subject). The issuer's user and root can read the source key; that is the legitimate issuer's access and the copy does not pretend otherwise. Everything from `/` down to the destination `tls` directory is root-owned and root-writable only, the relay's writable state lives elsewhere, and the copy refuses a path with a symlink or a foreign-owned component. A root step copies the one pair into a new generation directory under `/var/lib/mjolnir-relay/tls/`, created private before any key byte lands, checks that the key matches, the name matches and the dates are good, then swaps `current` by one rename. On failure `current` stays. The relay refuses to start without a good pair, never generates one, and exits when the one it serves expires.

**D5. Deny by default, one token profile.** A browser or Iroh session with no token, a bad token, or a token whose grant does not cover the path is refused. There is no public path and an Iroh endpoint id grants nothing. Tokens are moq-auth JWTs at the pinned revision. That format has `root`, `publish`, `subscribe`, `exp`, `iat`, `nbf` and `jti`, refuses unknown fields and ignores `iss`, so it cannot carry an audience. Purpose is bound by the key instead: the relay key file holds public keys whose private halves sign relay tokens and nothing else, and the relay holds no private key. Audience is bound the same way: a relay's audience is its `:relay_host`, and a signing key is trusted by exactly one host's key file, so a token for relay B fails at relay A as an unknown key. If two endpoints are ever meant to be one audience, that will be said in a change, not arrive by key reuse. EdDSA and ES256 only. Our admission adds what moq-auth leaves optional: an expiry, an issue time, a bounded lifetime, and a root under `t/<owner id>`. The session closes at expiry.

**D5a. Keys fail closed.** The key file is root-owned and replaced by rename. A bad file at start stops the unit. A bad file at reload refuses all new sessions. The relay writes the active file's hash, or `invalid`, to `/run/mjolnir-relay/keys.active`, so whoever rotated a key can see that it took. Retaining the old set on a bad reload was rejected: a revocation would then fail silently.

**D6. Tenant-rooted paths.** Every broadcast lives under `t/<owner id>/`. `<owner id>` is the canonical base58 id Mjolnir already uses as `owner_id`. What sits below that prefix is `add-relay-room-auth`'s to define. This change only fixes the prefix, so limits and metering can key on the second path segment.

**D7. No pulls.** The relay never dials an Iroh endpoint because a session named a ticket. Publishers push over a relay link. That removes the one way a client could make the host open connections of the client's choosing.

**D8. One owner of the relay's state.** `deploy.sh --relay` installs, updates, enables, disables and removes the unit and its one firewall rule (UDP 443 input, tagged `mjolnir-relay`), reading `:relay_enabled` and `:relay_host`. No other deploy touches either, in either direction. The rule is added only after the unit is active. On SIGTERM the relay refuses new sessions on both transports, waits up to `:relay_drain_seconds`, closes the rest and exits.

**D9. Off by default.** `:relay_enabled` false. Then no unit, no listener, no firewall change.

## What the host can see

The relay terminates QUIC. Whoever runs the host can read the media of every call that passes through it. Peer-to-peer Iroh calls do not have this property. moq has an `moq-e2ee` crate; using it is not in this change.

## Unverified hypotheses

- **relay-deps.** A crate on iroh 1.4 + aws-lc-rs builds beside the gateway on iroh 1.0 + ring. The throwaway workspace linked both and its tests ran. The relay is its own cargo package at `native/mjolnir_relay` so the gateway lock stays on ring. — go
- **relay-no-http.** `moq_relay::Relay` with `web.http.listen` unset accepted a WebTransport session. — go
- **relay-admission.** The admissions loop sees a browser JWT on `request.query` (`jwt=`), not on `request.token`, and refuses a session with neither. — go
- **relay-cert-reload.** `openssl s_client -quic -alpn h3` showed `CN=relay.test` while `current` was generation 1, then `relay-copy-cert.sh` renamed `current` to generation 2 and the next handshake showed `CN=second`. The session opened before the rename was still alive. The copy step does not restart the unit. Duke may reverse this. — go
- **cert-subject.** `issue_http01` takes any non-wildcard name and a private state directory and does not consult the app or site registries. `POST /api/certs/issue` still 404s a name that is neither. No public staging issue was run; the laptop has no public name. — go
- **viewer-https.** At moq `4a6f522`, `connect.ts` fetches `/certificate.sha256` only when `url.protocol === "http:"`. — go
- **relay-expiry-close.** A ten-second grant left the open phase inside the fifteen-second wait. — go
- **relay-key-loader.** `Key::public()` round-trips, a symmetric JWK cannot become a verify set, and the decider holds `Arc<Mutex<KeySet>>`. — go
- **relay-announce-scope.** A subscriber rooted at `t/a` saw `cam`; a subscriber rooted at `t/b` saw none of those names. — go
- **relay-drain-both.** Closing the admissions flag and calling `drain()` refused a new WebTransport session while the held one stayed connected. Iroh policy runs at accept, so the same flag refuses a new Iroh session. A live Iroh dial was not run. — go

## Where it is accepted

A real certificate needs a public name. The Framework laptop has none, so build and refusal tests run there with a throwaway certificate authority trusted by the test client, and the real-name journey runs on prod. Enabling it on prod is a human step.
