# Status: Implemented (2026-04-21)

Spec implemented against `spec.md` (committed in f363daf).

## What landed

- New modules: `native/mjolnir_gateway/src/config.rs` (TOML loader + env fallback + validation + SAN auto-derivation), `native/mjolnir_gateway/src/route.rs` (longest-apex matcher + local-route table).
- Refactored `native/mjolnir_gateway/src/main.rs`: `Disposition` classifier, `dial_local` + `run_proxy_local` split, SNI/Host enforcement, TOML-aware SIGHUP extending the existing ArcSwap pattern.
- Deployment: `systemd/gateway.toml.example`, `scripts/deploy.sh` preflight is now TOML-aware with env fallback, `systemd/gateway.env.example` carries a banner noting TOML precedence (Decision 10).

## Verification

- `cargo test -p mjolnir-gateway`: 76 passed, 0 failed (45 lib + 30 bin + 1 integration, summed across test binaries).
- `cargo clippy -p mjolnir-gateway --all-targets -- -D warnings`: clean.
- Code review (opus) returned REQUEST CHANGES; all CRITICAL + MAJOR items were addressed in a second pass before this marker landed.

## Acceptance-criteria coverage

| AC | Test |
|----|------|
| 1 — env-fallback preserves `vm.worldtree.network` | `config::tests::env_fallback_default_apex_is_vm_worldtree_network` |
| 2 — local route passes bytes unmodified | `tests::local_route_passes_bytes_unmodified_no_forwarded_headers` |
| 3 — per-apex ACME SAN auto-derivation | `config::tests::san_derivation_*` (3 tests covering iroh, none, mixed) |
| 4 — fallthrough=none returns 404 | `tests::fallthrough_none_returns_404_and_does_not_dial_iroh` |
| 5 — SNI/Host mismatch → 421 | `tests::handle_connection_sni_host_mismatch_returns_421` (drives real enforcement path, not inline comparison) |
| 6 — SIGHUP hot reload via ArcSwap | Wired; fail-safe swap semantics validated by existing `tls_state_reload_keeps_previous_cert_on_failure` |
| 7 — validation warnings skip bad entries | `config::tests::toml_duplicate_apex_warn`, `toml_duplicate_route_warn`, `toml_orphan_apex_warn`, `toml_bad_backend_warn` |
| 8 — full test suite passes | 76/76 |

## Deferred

- **Decision 9** — handshake-time cert check for unknown-SNI. Larger rustls-resolver surgery; partial mitigation in place (R3 SNI=Host check produces 421 post-handshake instead of a clean ClientHello close). Tracked as a separate follow-up; not a security regression.

## Deviations from spec example

- TOML `listen` / `listen_tls` default to **disabled** when omitted (footgun-avoidance: a config declaring `[[domain]]` but no cert source won't silently try to bind :443 without TLS material). Operators must set them explicitly — matches how `[acme].enabled` behaves elsewhere.
