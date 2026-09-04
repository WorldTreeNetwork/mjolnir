# Gateway Routing & Config Registration

How an inbound web request for a hosted app (e.g. `zine.identikey.io`) is resolved to a
running VM, and where every piece of that mapping is stored. Reference for the
`mjolnir-gateway` reverse proxy (`native/mjolnir_gateway/`) and its Elixir-side bindings.

> For the cold-start latency work that builds on this, see
> [`plans/gateway-local-routing.md`](plans/gateway-local-routing.md).

## Request path (today)

```
Browser ──TLS(SNI=zine.identikey.io)──> mjolnir-gateway  (:443 on the host)
   │  classify(Host) → match apex → subdomain
   │    1. lookup_local(apex, sub)  → [[route]] → Disposition::Local(SocketAddr)   [TCP]
   │    2. lookup_alias(apex, sub)  → [[alias]] → Disposition::Iroh(node z32)      [Iroh]
   │    3. apex.fallthrough = iroh    → decode sub as z32 node                     [Iroh]
   │       apex.fallthrough = none    → 404
   │       apex.fallthrough = parked  → 302 to park.worldtree.network (?from=)
   │                                    (the berth page itself is served there)
   │    (on apex MISMATCH) → sites_resolver → site or 302 to berth
   ▼
 backend: VM app (e.g. SvelteKit :3000) reached over local TCP or Iroh QUIC
```

`classify()` (`main.rs:565-585`) checks **local routes before Iroh aliases** — a local
`[[route]]` shadows the matching `[[alias]]`. `Disposition::Local` is a raw bidirectional
TCP proxy (`dial_local` → `run_proxy_local`); `Disposition::Iroh` dials the VM over Iroh
with a pooled connection (`setup_iroh_proxy`, TTL `pool_ttl_secs`, default 300s). Since
2026-07-01 a shadowed `[[alias]]` is **retained** as the route's Iroh fallback: if the
local dial fails, the gateway falls back to Iroh instead of returning 502.

## Where each mapping lives

| Mapping | Stored in | Notes |
|---|---|---|
| `host` → `(apex, subdomain)` | gateway `[[domain]]` list, longest-suffix match | `route.rs::match_host` |
| `(apex, sub)` → **local TCP backend** | gateway `[[route]] { apex, subdomain, backend }` | `backend` is a `SocketAddr`; checked first |
| `(apex, sub)` → **Iroh node** | gateway `[[alias]] { apex, subdomain, node, port }` | port appended as synthetic `<z32>-<port>` subdomain |
| custom domain → IdentiKey static site | `SecretStore` reverse index `_index/aliases/<fqdn>` → `{fp, site}` | served by `VanityHostPlug` on Bandit `:4000`, *not* the gateway |
| app name → VM | `Deploy.Registry` JSON `/var/lib/mjolnir/deploy/registry/<slug>.json` | `{app_name, release_snapshot, service_vm_id, url, custom_domain, port}` |
| custom domain → local route | generated `/etc/mjolnir/gateway.d/apps.toml` | rendered by `Mjolnir.Gateway.Routes`; merged over the base by the drop-in loader |
| VM → local IP | computed: `Mjolnir.Network.allocate_ip(vm_id)` | deterministic SHA256 → `10.200.0.0/10`; not stored |
| app → internal port | `Deploy.Registry.Entry.port` (+ `BuildPlan.port` from `Detector`, P0 hardcodes 3000) | now stored structured on the registry entry (2026-07-01) |

## Gateway config (`/etc/mjolnir/gateway.toml` + `gateway.d/*.toml`)

- **Base file** `/etc/mjolnir/gateway.toml`, resolved by `config::resolve_config_path()`
  (override: `GATEWAY_CONFIG`). Hand-maintained: apexes (`[[domain]]`), `[[cert]]`, ACME,
  server settings, and any hand-pinned `[[alias]]`.
- **Drop-in routes** `/etc/mjolnir/gateway.d/*.toml` (since 2026-07-01): `config::load()`
  merges their `[[route]]`/`[[alias]]` into the base. Drop-ins **cannot** declare apexes,
  certs, or server settings (a security boundary). This is where machine-generated routes
  live.
- **Routes are generated, not hand-edited.** `Mjolnir.Gateway.Routes` (Elixir) renders
  `/etc/mjolnir/gateway.d/apps.toml` from live VM state + `Deploy.Registry` custom domains +
  `:gateway_extra_domains`; `RouteReconciler` regenerates it on VM lifecycle + deploy events
  (debounced), then reloads. Feature-flagged `:gateway_routes_enabled` (on in prod).
- **Hot reload:** `systemctl reload mjolnir-gateway` → SIGHUP → re-`load()` (base + drop-ins)
  → atomic `ArcSwap` swap of the `RouteTable` (`main.rs:1338-1459`). A parse error keeps the
  previous config; in-flight connections keep their snapshot. Requires `ExecReload` in the
  unit (added 2026-07-01); listener addr changes still need a restart.

## TLS / certificates

- Per-domain Let's Encrypt via **DNS-01** (Cloudflare), SAN order over `AcmeConfig.domains`
  (`acme.rs`). Bring-your-own certs via `[[cert]]` entries (`config.rs`).
- **Custom domains feed the cert SAN list**: `config.rs` derives SANs that include aliases
  under a `none` apex (test `san_derivation_includes_alias_under_none_apex`). So adding a
  custom domain needs *both* a routing entry *and* cert coverage — they are coupled and
  should be automated together.

## VM IP allocation

`Mjolnir.Network.allocate_ip/1` (`lib/mjolnir/network.ex:149-179`): `SHA256(vm_id)` →
offset into `10.200.0.0/10` (avoids `.0`/`.255` last octet). Pure function of `vm_id`:

- **Stable** across VM restart / dormancy restore (vm_id is preserved by `spawn_with_id`).
- **Changes on redeploy** — a redeploy spawns a *new* service VM with a new vm_id, hence a
  new IP. Any cached route to the old IP must be regenerated at cutover.
- Collision probability is negligible at current scale (/10 = ~4M addresses) but unbounded;
  tracked for a future hardening pass.

## App → VM binding (`Deploy.Registry`)

`Deploy.Runtime.start/3` (`lib/mjolnir/deploy/runtime.ex`): build → spawn service VM from
`release_snapshot` → await Iroh ticket → install systemd unit (with `PORT`) inside the VM →
`registry_put(app_name, %{release_snapshot, service_vm_id, url})` → on redeploy, stop the
previous VM (cutover). One JSON file per app.

### Binding fields & remaining gaps

`Deploy.Registry.Entry` now carries `custom_domain` + `port` (added 2026-07-01), so the
route generator derives `(subdomain, apex) → backend` from the binding rather than a
hand-edited config. Remaining gaps:

- No `host` field — can't tell which physical host a VM is on (needed for local-vs-remote
  routing once there's more than one host). The generator emits routes only for VMs it sees
  running locally.
- Write-once on deploy; not reconciled/observed against live VM state. The `RouteReconciler`
  compensates by regenerating on lifecycle events; folding the whole thing into Forge (so it
  converges/drifts/prunes like any host resource) is tracked as `mjolnir-l79.6`.
- `zine` is not in `Deploy.Registry` (hand-provisioned) — covered via `:gateway_extra_domains`
  config until backfilled.

The automation gap is closed: gateway routes are rendered from the binding + live VM state,
not hand-edited. See [`plans/gateway-local-routing.md`](plans/gateway-local-routing.md).

## Parked names (`fallthrough = "parked"`)

A parking apex (today: `identikey.me`) is a namespace of names that exist before a
machine does. The berth page itself lives at `https://park.worldtree.network/`.
Unbound parked names, and Sites alias misses, **302** there with `?from=<original-host>`.
The page keeps its existing lede and mentions the original name as an aside.
Binding a name does **not** invent a new registry: it writes the same
`[[alias]]` the rest of the gateway already understands.

### How to point a name

```
park.identikey.me.   CNAME   vm.worldtree.network.
*.identikey.me.      CNAME   vm.worldtree.network.
identikey.me.        A       45.76.77.97
```

`identikey.me` is not in the worldtree ACME zone, so TLS is Origin-CA / BYO
(`[[cert]]`), same as `zine.identikey.io`. A wildcard Origin cert covering
`*.identikey.me` + `identikey.me` is what makes the namespace work; a single-host
cert covers only the seed name.

### How to reference the service

| Identity | What it is | Use |
|---|---|---|
| **Vanity name** (`park.identikey.me`) | DNS label humans type | The registry key. Not a network address. |
| **Iroh node ID** (z32) | Ed25519 pubkey of the guest endpoint | **The service pointer.** Reachable through NAT via relay/holepunch. Survives respawn if the guest keeps the key. This is `[[alias]] node=`. |
| **XID / Identikey fingerprint** | Owner / actor identity | Who is allowed to bind the name. Not something the gateway can dial. |
| **VM UUID** | Host-local process id | Changes on redeploy. Do not put this in DNS or the alias table. |
| **TAP IP** (`10.200.x.x`) | Host-local L2 address | Fast path only, and only when the VM is on *this* host. `Mjolnir.Gateway.Routes` already writes `[[route]]` for that. |

Iroh magicsock does cache paths (direct / holepunch / relay). That is **not** a
substitute for the TAP `[[route]]`: a cold Iroh dial on a co-located VM was ~7s;
host→guest TCP was 5.5ms. Keep using the existing local-route overlay. Do not
build a third cache table until a name actually serves over Iroh from another
host.

The durable record is:

```toml
[[alias]]
apex      = "identikey.me"
subdomain = "park"
node      = "<z32 iroh node id>"
port      = 3000
```

Local `[[route]]` (TAP IP) is derived later, when the VM is observed running here.
If the local dial fails, the gateway already fails over to the retained Iroh alias.
