# Gateway Local Routing — kill the cold-start for co-located VMs

**Status:** Design (no code yet)
**Author:** investigation 2026-06-30
**Problem:** `zine.identikey.io` spins ~7s on first load, then is fast (~138ms warm),
then re-spins after ~5 min idle. Email clients give up before images load.

## TL;DR

The gateway and the zine VM are on the **same physical host** (`45.76.77.97`), yet the
gateway reaches the VM by dialing it over **Iroh's global overlay** (n0 public relay +
NAT hole-punch). The first `ep.connect()` on a cold pool entry is the ~7s; the pool TTL
is 300s so the cost recurs. The fix is to proxy co-located VMs **directly over local TCP**
to the VM's TAP IP, reserving Iroh for genuinely remote hosts. The gateway already
supports this (`[[route]]` → local backend, checked *before* the Iroh alias). The work is
almost entirely **config-plane**, not data-plane.

## Evidence (root cause)

- DNS: `zine.identikey.io` → CNAME `vm.worldtree.network` → A `45.76.77.97`. No CDN/edge.
- TLS terminated by `mjolnir-gateway` directly (per-domain Let's Encrypt, HTTP/1.1 only).
- App is **live SvelteKit `adapter-node` + `sirv`** inside a VM (headers: `x-sveltekit-page: true`,
  asset etags `W/"<len>-<mtime>"`, `cache-control: public,max-age=31536000,immutable`).
  → it is the **app/Iroh path**, *not* the static IdentiKey-Sites path.
- Gateway dial: `native/mjolnir_gateway/src/main.rs` `setup_iroh_proxy` →
  `ep.connect(addr, TCP_FWD_ALPN)`, `connect_timeout = 15s`, pool TTL `300s`
  (`config.rs`). Guest blocks 2–5s on `endpoint.online().await`
  (`native/mjolnir_guest_agent/src/iroh.rs:61`, "wait for relay connection").
- Dormancy is **not** the cause: wake-from-snapshot is 30–60s; 7s is connection setup.

## The seam (why this is mostly config)

`classify()` in `main.rs:565-585` already prefers a local route over the Iroh alias:

```rust
if let Some(backend) = table.lookup_local(apex, &subdomain) {
    return Disposition::Local(apex, subdomain, backend);   // checked FIRST
}
if let Some(target) = table.lookup_alias(apex, &subdomain) {
    return Disposition::Iroh(apex, target);                // fallback
}
```

Proven by the existing test `route_precedes_iroh_under_fallthrough_iroh`. `Disposition::Local`
is a raw TCP proxy: `dial_local(backend)` → `run_proxy_local()` (replays buffered headers,
pipes bytes — no Iroh, no per-request client). So a `[[route]]` for
`zine.identikey.io → <VM-TAP-IP>:3000` **shadows** the Iroh alias and serves over local TCP.
The alias stays as an automatic fallback for the multi-host future.

## Facts that constrain the design

| Fact | Source | Implication |
|---|---|---|
| VM TAP IP = `Network.allocate_ip(vm_id)`, deterministic SHA256, range `10.200.0.0/10` | `lib/mjolnir/network.ex:149-179` | Pure function of `vm_id`; gateway on same host can dial `10.200.x.x:3000` directly |
| IP stable across restart/restore (vm_id preserved by `spawn_with_id`) but **changes on redeploy** (new VM, new vm_id) | dormancy report; `deploy/runtime.ex` cutover | Route must be **regenerated on deploy cutover** |
| `zine` → `service_vm_id` lives in `Deploy.Registry` (`/var/lib/mjolnir/deploy/registry/zine.json`) | `lib/mjolnir/deploy/registry.ex:26-45` | Generator can derive backend = `allocate_ip(service_vm_id):port` |
| Port 3000 from `BuildPlan`/`Detector` (hardcoded P0), baked into `url` only | `deploy/detector.ex:35`, `runtime.ex:255` | Store port explicitly for the generator |
| Custom domain (`zine.identikey.io`) is **only** in hand-maintained `[[alias]]`; not in Registry.Entry | gateway.toml.example; registry.ex | Must add `custom_domain` to the binding to automate |
| `gateway.toml` is a **single hand-maintained file**, no include/merge; `load()` reads one path | `config.rs:272,409` | Either Elixir renders whole file, or add a drop-in dir loader |
| Reload = `systemctl reload mjolnir-gateway` (SIGHUP → re-`load()` → `ArcSwap` swap; bad config keeps previous) | `main.rs:1338-1459` | Zero-downtime activation; safe on parse error |
| Local-dial failure → 502, does **not** fall back to Iroh | `main.rs:868-881` | Stale route is fatal unless we add failover |

## Plan (phased)

### Phase 0 — Manual proof — ✅ VALIDATED LIVE 2026-06-30
Applied against the running zine VM and confirmed end-to-end:

- zine VM = `076adf62-b3e1-4696-8427-1b20faf3fd9c`, guest IP `10.237.178.231` (from
  `GET /api/vms` — the API already exposes `guest_ip`, no need to recompute `allocate_ip`).
- **host→guest `:3000` direct: `ttfb=0.0056s`** (5.5 ms) vs ~7s cold over Iroh.
- Added to `/etc/mjolnir/gateway.toml` (backup: `gateway.toml.bak-localroute`):
  ```toml
  [[route]]
  apex      = "identikey.io"
  subdomain = "zine"
  backend   = "10.237.178.231:3000"
  ```
- Reloaded via `systemctl kill -s HUP mjolnir-gateway` (the unit has **no `ExecReload`**, so
  `systemctl reload` is a no-op — see findings).
- Gateway logged `config.alias_shadowed_by_route … skipping alias`, `route_count=2
  alias_count=0`, and every zine request now logs `apex=identikey.io subdomain=zine
  route="local"`. Public HTTPS steady at **64–141 ms**, zero 7s spikes.

**The 7s is gone for zine.** This route is stable across restart/restore but will go stale
on redeploy (new VM → new guest IP); Phase 2 automates regeneration.

### Findings from the live run (feed these into Phases 1–3)
1. **TOML apex key is `[[domain]]`** (with `fallthrough`), not `[[apex]]`; `[[route]]` /
   `[[alias]]` / `[[cert]]` as documented. An existing `mimir.worldtree.network → 127.0.0.1:3000`
   route confirms the shape.
2. **The loader DROPS a shadowed alias** (`alias_count` → 0) — it is not retained. So Phase 3's
   "fall back to the alias" needs the loader to *keep* shadowed aliases as a fallback list (or
   the route to carry an optional fallback node). This makes Phase 3 a loader change, not just a
   handler change.
3. **`mjolnir-gateway.service` has no `ExecReload`** → reload must be `systemctl kill -s HUP`
   (or add `ExecReload=/bin/kill -HUP $MAINPID` to the unit; recommended so the generator can
   use `systemctl reload`).
4. **zine is NOT in `Deploy.Registry`** — it was provisioned manually. So the Phase 2 generator
   can't assume every served app has a registry entry; it should derive routes from **live VM
   state** (`/api/vms` gives `id`, `guest_ip`, `ticket`) joined to the domain→VM intent, and/or
   backfill the registry. Reading `guest_ip` from the API is simpler and more robust than
   recomputing `allocate_ip(vm_id)`.

### Phase 1 — Drop-in config loader (small Rust, ~40 lines + tests)
Extend `config::load` to also read `/etc/mjolnir/gateway.d/*.toml` and merge their
`[[route]]`/`[[alias]]` into the base (apexes/certs/sites_resolver stay in `gateway.toml`).
Keeps machine-generated routes cleanly separated from the hand-maintained base; SIGHUP
already re-runs `load()`. *Alternative (zero Rust):* Elixir renders the entire
`gateway.toml` from an operator base template + generated route blocks.

### Phase 2 — Elixir route generator (`Mjolnir.Gateway.Routes`)
- Add `custom_domain` (or `domains: [..]`) + `port` to `Deploy.Registry.Entry`; set at
  deploy time (`mj deploy --domain zine.identikey.io`, or app config).
- New module renders `/etc/mjolnir/gateway.d/apps.toml` from `Deploy.Registry`: for each
  app with a custom domain whose VM is on **this host**, emit
  `[[route]] apex, subdomain, backend = "#{allocate_ip(vm_id)}:#{port}"`. Atomic write +
  `systemctl reload mjolnir-gateway`. Full re-render each time (small N), idempotent.
- Trigger regeneration on: deploy cutover (after `registry_put`), EventBus
  `:vm_restored` / `:vm_started` / resume, and Mjolnir boot (reconcile).

### Phase 3 — Self-healing failover (small Rust, recommended)
In `handle_connection`, when `Disposition::Local` dial fails **and** an alias exists for the
same `(apex, subdomain)`, fall back to `handle_iroh_connection`. Makes a stale route
non-fatal — and is the exact seam for multi-host (local-first, Iroh-for-remote).

## Multi-host future (no corner painted)
The generator only writes local routes for VMs on the current host; VMs on other hosts stay
Iroh aliases. "Is the target local?" generalizes to a control-plane routing table the Elixir
cluster maintains; Iroh remains the **inter-host** transport and global hole-punch
(laptops/edge nodes join without Tailscale). Phase 3 failover covers VM migration. Nothing
here blocks that; it builds toward it.

## Secondary wins (cheap, independent of the root fix)
- Raise `pool_ttl_secs`; add keepalive pre-warm so published-site Iroh conns don't go cold.
- Fix per-request `reqwest::Client` in `sites.rs:37` (build once, reuse).
- Enable HTTP/2 at the gateway (multiplex the ~10 `_app/immutable/*` asset requests).
- Host-side cache of immutable assets so they never touch the VM.
- Real CDN last — origin is fast by then, so it's pure geo/latency win.

## Risks / validation
- Host→guest `:3000` reachability: validated by Phase 0 (guest must bind `0.0.0.0:3000`).
- SNI≡Host enforcement (`main.rs:847`) is pre-classify and host-based — unaffected.
- Atomic write + SIGHUP: parse failure keeps previous config (`main.rs:1443`) — safe.
- Without Phase 3, a missed regeneration event = 502 until next render; the Iroh alias
  fallback (Phase 3) removes that sharp edge.
