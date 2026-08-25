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
- Host matches no declared apex → 400 `DomainMismatch` (connection closed cleanly; no cert served, no backend consulted).

Each `[[domain]]` declares a **fallthrough mode** that controls what happens when no explicit `[[route]]` matches the subdomain:

- `fallthrough = "iroh"` (default) — unmatched subdomains are decoded as z32 Iroh node IDs. Apex-level cert covers `{*.<apex>, <apex>}`. This is the VM-fanout mode used by `vm.worldtree.network`.
- `fallthrough = "none"` — unmatched subdomains return 404. Apex-level cert covers `{<apex>} ∪ {route subdomain hostnames under this apex}` only. This is the hand-curated services mode (e.g., `worldtree.network` serving only `git.` and nothing else). No wildcard cert is issued for these apexes, reducing both attack surface and subdomain-enumeration leakage.

### R2 — Local backend routing

- A `(apex, subdomain) → backend` map pins specific hostnames to a local TCP endpoint (typically `127.0.0.1:<port>`).
- Lookup order inside the proxy setup path: resolve `(apex, subdomain)`; if the pair has a local route, TCP-connect to that backend and hand off to the existing `run_proxy` byte-copy. Only if there is no local route does the gateway fall through to z32 decoding and the Iroh path.
- Route matching uses the **raw subdomain string** (lowercased). Port-suffix splitting (`<z32>-<port>`) is an Iroh-path-only concern and must not affect local-route lookup.
- Local path reuses `run_proxy` and the headers already buffered by `read_until_headers`. `Host` is preserved. The gateway **sets `X-Forwarded-Proto`** to `https` on the TLS listener and `http` on :80 (overwriting any client-supplied value) so backends that emit `Secure` session cookies actually `Set-Cookie`. `X-Forwarded-For` / PROXY-protocol for client IP recovery remains a future story.
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
vm_default_port         = 80   # VM target port when none specified in a -<port> suffix
connect_timeout_secs    = 15
response_timeout_secs   = 0    # 0 = no timeout
pool_ttl_secs           = 300
pool_max                = 256
pool_probe_timeout_secs = 10

[acme]
enabled = true
email   = "duke@worldtree.io"
directory = "https://acme-v02.api.letsencrypt.org/directory"
renew_before_secs = 2592000
cloudflare_api_token_file = "/etc/mjolnir/cloudflare-token"   # one-line token, whitespace trimmed
# Optional: explicit override of auto-derived SAN list. Usually leave unset —
# see Decision 7 below.
# domains = ["*.vm.worldtree.network", "vm.worldtree.network", "git.worldtree.network"]

# VM-fanout apex: every subdomain is an Iroh ticket unless pinned by a route.
# Cert auto-derivation: {*.vm.worldtree.network, vm.worldtree.network}.
[[domain]]
suffix      = "vm.worldtree.network"
fallthrough = "iroh"    # default; can be omitted

# Hand-curated apex: only explicit routes serve; unmatched subdomains 404.
# Cert auto-derivation: {worldtree.network, git.worldtree.network}
# (bare apex + each declared route subdomain, no wildcard).
[[domain]]
suffix      = "worldtree.network"
fallthrough = "none"

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

- Unit tests for:
  - Apex longest-suffix matching (overlapping and non-overlapping cases).
  - Route-vs-Iroh precedence under `fallthrough = "iroh"`.
  - Route lookup uses raw subdomain, **before** port-suffix splitting: a route declared as `subdomain = "git-3001"` matches a request to `git-3001.<apex>` and is **not** split into `git` + port `3001`.
  - Case normalization (`Git` in TOML matches `git` in Host).
  - `fallthrough = "none"` returns 404 for unmatched subdomains (no Iroh decode attempt).
  - SNI/Host mismatch rejection on the TLS path (421).
  - TOML load: minimal valid, full valid, duplicate apex (warn), duplicate route (warn), orphan apex (warn), unparseable backend (warn), wildcard in apex suffix (fatal), empty apex list (fatal), TOML parse error (fatal).
  - SAN list auto-derivation: `iroh` mode yields `{*.<apex>, <apex>}`; `none` mode yields `{<apex>} ∪ {<sub>.<apex> | each declared route}` with no wildcard.
- Integration tests (may use `tokio::net::TcpListener` as a stub backend):
  - Local-route end-to-end: original `Host` is preserved; `X-Forwarded-Proto` is set (`https` on TLS, `http` on :80).
  - Fallthrough to Iroh when no route matches under `fallthrough = "iroh"` (expected `InvalidTicket` is the signal the fallthrough fired).
  - `fallthrough = "none"` on an undeclared subdomain returns 404 with no Iroh connection attempt (observable because no Iroh endpoint was dialed).
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
   - `[[domain]] suffix` containing `*` or not a valid FQDN → **fatal**.
   - `fallthrough` value outside `{"iroh", "none"}` → **fatal**.
   - Non-ASCII / IDN hostnames in any apex, subdomain, or route → **fatal** (punycode support deferred).
7. **ACME SAN list is per-apex auto-derived.** When `[acme].domains` is not explicitly set, the cert SAN list is derived from each `[[domain]]` according to its `fallthrough` mode:
   - `fallthrough = "iroh"` → include `*.<apex>` and `<apex>`.
   - `fallthrough = "none"` → include `<apex>` and, for each `[[route]]` under this apex, `<subdomain>.<apex>`. No wildcard. This avoids issuing a wildcard cert for an apex that serves only a hand-picked set of hostnames (both reduces attack surface and stops leaking "we have a cert for literally anything here" to observers).
   - If `[acme].domains` **is** set, it overrides auto-derivation verbatim.
8. **Hot reload covers config + routes + certs; listener addresses require restart.** SIGHUP re-reads the TOML (or env fallback), re-validates, atomically swaps the route table via `arc-swap`, and feeds the updated apex/SAN list into the existing ACME renewal path. On validation failure, keep the previous config and log the parse error loudly. Changes to `listen` / `listen_tls` are **ignored** by SIGHUP (log a warn noting "listener change requires restart"); rebinding listeners mid-flight would drop in-flight connections, which we don't want to do silently.
9. **No lazy/on-handshake cert issuance.** Certs for every declared hostname are issued at startup (and on SIGHUP when the apex or route set changes). A request with SNI for a hostname that has no cert at handshake time is treated the same as no-apex-match: close after the ClientHello without completing handshake. This keeps the handshake path deterministic; the operator gets a loud `warn` log at startup instead of a surprise 500 on first request.
10. **Env → TOML transition is startup-only.** The TOML-vs-env decision is made at process start. If `/etc/mjolnir/gateway.toml` exists when the process boots, TOML is authoritative and env vars are ignored. If it doesn't, env mode is used and a TOML file that appears later has no effect until the process restarts. SIGHUP reloads whichever mode was chosen at boot.
11. **Cert storage unchanged.** ACME state stays under systemd's `StateDirectory` (today `/var/lib/mjolnir-gateway/acme/`, see `acme::AcmeConfig.state_dir`). `fullchain.pem` + `privkey.pem` + `metadata.json` via atomic rename. No new config keys needed.
12. **Cloudflare token loading.** Prefer `cloudflare_api_token_file` pointing at a file. The file contains the token as a single line; surrounding whitespace is stripped; no JSON, no prefix, no key=value. If the file setting is absent, fall back to the `CLOUDFLARE_API_TOKEN` env var (current behavior). Never embed the token in TOML itself; never log it.
13. **Bare apex (no wildcard) in `[[domain]] suffix`.** The `suffix` field is a bare FQDN, e.g. `worldtree.network`. Writing `*.worldtree.network` is rejected with a clear error — wildcards are a property of the cert SAN list (point 7), not of the apex declaration.

## Acceptance Criteria

1. **Binary drop-in on production:** with no `/etc/mjolnir/gateway.toml` present, the binary uses the existing `GATEWAY_*` env vars and behaves identically to the pre-upgrade deployment. Current `vm.worldtree.network` deployment survives upgrade with zero config change.
2. **Multi-apex + local route:** with a TOML file declaring apexes `vm.worldtree.network` + `worldtree.network` and a route `worldtree.network/git → 127.0.0.1:3000`, a GET to `https://git.worldtree.network/` reaches a stub on port 3000 with original `Host` preserved and `X-Forwarded-Proto: https`.
3. **ACME SAN list is per-apex:**
   - An apex with `fallthrough = "iroh"` yields a cert covering `{*.<apex>, <apex>}`.
   - An apex with `fallthrough = "none"` yields a cert covering `{<apex>}` plus `{<sub>.<apex>}` for each declared route under that apex. **No** wildcard is in the SAN list.
   - Renewal preserves the computed coverage; changes to `[[domain]]`/`[[route]]` followed by SIGHUP update the SAN list on the next renewal cycle.
4. **Fallthrough = "none" enforces explicit routing:** a request to `unknown.worldtree.network` (where `worldtree.network` is declared `fallthrough = "none"` and no `[[route]]` matches `unknown`) returns 404; no Iroh endpoint is dialed.
5. **SNI/Host enforcement:** a connection negotiated with SNI `git.worldtree.network` that then sends `Host: admin.worldtree.network` is closed with HTTP 421 before proxying.
6. **Hot reload:** SIGHUP with a valid modified TOML (new route added, existing route removed) swaps the table within one request's worth of latency; in-flight connections finish on the old table. Changes to `listen`/`listen_tls` are ignored by SIGHUP with a warn log. A SIGHUP with an invalid TOML logs the error and leaves the running config untouched.
7. **Validation warnings, not crashes:** misconfigured routes (duplicate, orphan apex, bad backend address) log warnings and are skipped; the gateway continues to serve the remaining valid routes.
8. **`cargo test -p mjolnir-gateway` passes**, including new tests for apex matching, route precedence (both fallthrough modes), SNI/Host equality, TOML parse cases, SAN auto-derivation, case normalization, and the port-suffix/route non-split rule.

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
