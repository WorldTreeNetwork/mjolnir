# Gateway: Multi-Domain Support + Local HTTP Backend Routing

## Goal

The gateway (`native/mjolnir_gateway/`) currently serves a single apex (default `vm.worldtree.network`) and routes every subdomain to an Iroh peer via z32-decoded node IDs. We want two things in one pass:

1. **Host it on other people's servers under their own apexes** (e.g., Alice runs it for `*.alice.dev`, Bob for `*.bob.net`; one deployment may legitimately own several apexes).
2. **Route some subdomains to local TCP services on the gateway host itself** — immediate concrete need: a Forgejo instance on `127.0.0.1:3000` reachable as `git.worldtree.network`.

This replaces the `GATEWAY_DOMAIN` single-apex assumption with a list, and introduces a `(apex, subdomain) → local-backend` map that takes precedence over Iroh decoding. Aims for *robust and working*, not perfect — bias to warnings over fatal errors where a skew doesn't affect security.

## Requirements

### R1 — Multi-apex matching

- Accept a **list** of apex suffixes (was: single `GATEWAY_DOMAIN`).
- For each incoming request, pick the **longest matching apex** from the list (case-insensitive); the substring before the matching apex is the subdomain.
- Match requires a literal `.<apex>` boundary (i.e. `git.vm.worldtree.network` matches apex `vm.worldtree.network`, not `evm.worldtree.network`).
- Empty subdomain (request Host equals an apex exactly, no dot prefix) → 400 `EmptySubdomain`. Apex-only routing is out of scope for this iteration.
- Host matches no declared apex → 400 `DomainMismatch`.

### R2 — Local backend routing

- A `(apex, subdomain) → backend` map pins specific hostnames to a local TCP endpoint (typically `127.0.0.1:<port>`).
- Lookup order inside the proxy setup path: resolve `(apex, subdomain)`; if the pair has a local route, TCP-connect to that backend and hand off to the existing `run_proxy` byte-copy. Only if there is no local route does the gateway fall through to z32 decoding and the Iroh path.
- Route matching uses the **raw subdomain string** (lowercased). Port-suffix splitting (`<z32>-<port>`) is an Iroh-path-only concern and must not affect local-route lookup.
- Local path reuses `run_proxy` and the headers already buffered by `read_until_headers` — no header rewriting (no `Host`, no `X-Forwarded-*`). The backend sees the request byte-identical to what arrived at the gateway. Services needing client IP recovery will get PROXY-protocol support in a future story.
- Connection timeout to the local backend uses `GATEWAY_CONNECT_TIMEOUT`. Failure → 502 `LocalBackendUnreachable`.

### R3 — SNI/Host enforcement

On the TLS path, the TLS handshake's SNI value must equal (case-insensitive) the HTTP `Host` header received over the negotiated connection. Mismatch → 421 `MisdirectedRequest`, close the connection.

**Why this matters:** we are intentionally offloading the authenticity guarantee from Iroh's pubkey-binding to the web PKI. Without SNI=Host enforcement, a client holding a valid cert for apex A's subdomain could reach apex B's backend over the same connection by lying in the `Host` header. Strict equality closes that gap.

### R4 — Configuration: TOML first, env fallback

Primary config is TOML at `/etc/mjolnir/gateway.toml` (path overridable via `GATEWAY_CONFIG`). Fallback to current env-vars if the TOML file is absent, preserving the live `vm.worldtree.network` deployment across a binary swap.

Proposed shape (implementer may refine names):

```toml
# /etc/mjolnir/gateway.toml

listen      = "0.0.0.0:80"     # plain HTTP listener; empty string to disable
listen_tls  = "0.0.0.0:443"    # TLS listener; empty string to disable
default_port          = 80
connect_timeout_secs  = 15
response_timeout_secs = 0     # 0 = no timeout
pool_ttl_secs         = 300
pool_max              = 256
pool_probe_timeout_secs = 10

[acme]
enabled = true
email   = "duke@worldtree.io"
directory = "https://acme-v02.api.letsencrypt.org/directory"
renew_before_secs = 2592000
cloudflare_api_token_file = "/etc/mjolnir/cloudflare-token"   # or env
# Optional: override auto-derivation (see Decisions below).
# domains = ["*.vm.worldtree.network", "vm.worldtree.network"]

# Each [[domain]] declares an apex suffix the gateway serves.
[[domain]]
suffix = "vm.worldtree.network"

[[domain]]
suffix = "worldtree.network"

# Each [[route]] pins a (apex, subdomain) to a local TCP backend.
# Subdomain strings are lowercased at load time; matching is case-insensitive.
[[route]]
apex      = "worldtree.network"
subdomain = "git"
backend   = "127.0.0.1:3000"
```

### R5 — Observability

- On startup: log resolved apex list, route count, and TLS/ACME mode at `info!`. Log each route at `debug!`.
- On connection: one `info!` line per request decision: `peer=<addr> apex=<apex> subdomain=<sub> route=local|iroh`. Trivial grep target.
- Never log the Cloudflare API token, ACME account key, or cert private key. Token in env/file only.
- `LocalBackendUnreachable` carries the backend address in the log; the HTTP 502 body is a generic `"Bad Gateway"` (no backend leakage to the client).

### R6 — Testing

- Unit tests for: apex longest-suffix matching (overlapping and non-overlapping), route-vs-Iroh precedence, route lookup with port-suffix-looking subdomains (`git-web` must not be split), case normalization, SNI/Host mismatch rejection, TOML load (minimal, full, rejected cases).
- Integration tests (may use `tokio::net::TcpListener` as a stub backend): local-route end-to-end with bytes verified unmodified at the backend; fallthrough to Iroh when no route matches (expected `InvalidTicket` is the signal).
- Existing `test_parse_subdomain_*` tests continue to pass.

## Decisions

These pin down the ambiguities the previous draft left open. Implementer should treat them as binding unless a code reading reveals a reason to deviate — in which case, raise and resolve before coding.

1. **Apex-only routing: out of scope.** Empty subdomain returns 400. Revisit in a future story if the apex needs its own backend (e.g., a landing page on `worldtree.network/`).
2. **ACME provider: Cloudflare DNS-01 only.** Consistent with current `acme.rs`/`cloudflare.rs`. No provider trait / abstraction in this iteration.
3. **Default ports: `:80` + `:443`.** The `:8080` plain HTTP default is legacy-only (lives in env-var fallback). The new TOML world binds `:80` directly — no point keeping an unprivileged-port detour when the service already runs with `CAP_NET_BIND_SERVICE`.
4. **SNI must equal Host.** Case-insensitive equality. Mismatch = 421, close. Not negotiable — it's the thing that makes this a real reverse proxy rather than a Host-header-trustful tunnel.
5. **Case normalization.** Apex and subdomain values in TOML are lowercased on load. All matching is case-insensitive. UTF-8 non-ASCII hostnames (IDN/punycode) are out of scope this iteration — reject at load time with a clear error.
6. **Validation strictness:**
   - Duplicate `[[domain]]` suffix → **warn, keep first**, skip rest.
   - Duplicate `(apex, subdomain)` route → **warn, keep first**, skip rest.
   - Route with `apex` not in any `[[domain]]` → **warn, skip that route**.
   - Unparseable `backend` address → **warn, skip that route**.
   - Empty `[[domain]]` list → **fatal**. Gateway has nothing to serve.
   - TLS listener enabled with no ACME and no static cert → **fatal**.
   - TOML parse error → **fatal**, log the parse error verbatim, do not fall back to env.
7. **`[acme].domains` auto-derivation.** If `[acme].domains` is **not set**, the gateway derives the cert SAN list as `{"*.<apex>", "<apex>"}` for each `[[domain]]`. If `[acme].domains` **is set**, it overrides auto-derivation verbatim. This keeps the common case zero-configuration and avoids cert/route skew.
8. **Hot reload covers everything.** SIGHUP re-reads the TOML (or env fallback), re-validates, and atomically swaps in the new route table **and** reloads certs through the existing `ExpiryAwareResolver` (`arc-swap`). On validation failure, keep the previous config and log loudly. This closes the "routes skewed from certs" trap the previous draft introduced by forbidding route hot-reload.
9. **Cert storage.** ACME state lives under systemd's `StateDirectory` (today `/var/lib/mjolnir-gateway/acme/`, see `acme::AcmeConfig.state_dir`). Contains `fullchain.pem`, `privkey.pem`, `metadata.json` written via atomic rename. No change needed for this spec.
10. **Cloudflare token loading.** Prefer a file path (`cloudflare_api_token_file`) over inline-in-TOML. If absent, fall back to the `CLOUDFLARE_API_TOKEN` env var (current behavior). Never embed the token in TOML or logs.

## Acceptance Criteria

1. **Binary drop-in on production:** with no `/etc/mjolnir/gateway.toml` present, the binary uses the existing `GATEWAY_*` env vars and behaves identically to the pre-upgrade deployment. Current `vm.worldtree.network` deployment survives upgrade with zero config change.
2. **Multi-apex + local route:** with a TOML file declaring apexes `vm.worldtree.network` + `worldtree.network` and a route `worldtree.network/git → 127.0.0.1:3000`, a GET to `https://git.worldtree.network/` reaches a stub on port 3000 with bytes unmodified (no `X-Forwarded-*` added, original `Host` preserved).
3. **ACME covers all apexes:** on cold start, ACME issues a cert whose SANs cover `{*.<apex>, <apex>}` for every declared apex. Renewal preserves that coverage.
4. **SNI/Host enforcement:** a connection negotiated with SNI `git.worldtree.network` that then sends `Host: admin.worldtree.network` is closed with HTTP 421 before proxying.
5. **Hot reload:** SIGHUP with a valid modified TOML (new route added, existing route removed) swaps the table within one request's worth of latency; in-flight connections finish on the old table. A SIGHUP with an invalid TOML logs the error and leaves the running config untouched.
6. **Validation warnings, not crashes:** misconfigured routes (duplicate, orphan apex, bad backend address) log warnings and are skipped; the gateway continues to serve the remaining valid routes.
7. **`cargo test -p mjolnir-gateway` passes**, including new tests for apex matching, route precedence, SNI/Host equality, TOML parse cases, and case normalization.

## Non-goals (do not do these in this iteration)

- Per-path routing (subdomain is the only routing key).
- Header rewriting or `X-Forwarded-For` / PROXY protocol (future story).
- Multiple backends per subdomain, load balancing, health checking.
- mTLS or TLS to the local backend — plaintext TCP only.
- ACME provider abstraction beyond Cloudflare DNS-01.
- Apex-only (empty subdomain) routing.
- Per-route auth, rate limiting, or bot detection.

## Implementation starting point

Code lives in `native/mjolnir_gateway/src/`. Begin by extending `struct Config` in `main.rs` with the TOML layer, then introduce a `route` module holding the `(apex, subdomain) → backend` table and the longest-apex matcher. TLS/ACME already uses `arc-swap` for hot-reload — wrap the route table in the same pattern and fold route-reload into the existing SIGHUP handler. Don't trust the spec's naming more than the existing module names; adjust if `main.rs` has already moved things.
