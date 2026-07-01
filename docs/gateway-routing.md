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
   │    3. apex.fallthrough = iroh  → decode sub as z32 node                       [Iroh]
   │       apex.fallthrough = none  → 404
   │    (on apex MISMATCH) → sites_resolver → Mjolnir Sites backend               [TCP]
   ▼
 backend: VM app (e.g. SvelteKit :3000) reached over local TCP or Iroh QUIC
```

`classify()` (`main.rs:565-585`) checks **local routes before Iroh aliases** — a local
`[[route]]` shadows the matching `[[alias]]`. `Disposition::Local` is a raw bidirectional
TCP proxy (`dial_local` → `run_proxy_local`); `Disposition::Iroh` dials the VM over Iroh
with a pooled connection (`setup_iroh_proxy`, TTL `pool_ttl_secs`, default 300s).

## Where each mapping lives

| Mapping | Stored in | Notes |
|---|---|---|
| `host` → `(apex, subdomain)` | gateway `[[apex]]` list, longest-suffix match | `route.rs::match_host` |
| `(apex, sub)` → **local TCP backend** | gateway `[[route]] { apex, subdomain, backend }` | `backend` is a `SocketAddr`; checked first |
| `(apex, sub)` → **Iroh node** | gateway `[[alias]] { apex, subdomain, node, port }` | port appended as synthetic `<z32>-<port>` subdomain |
| custom domain → IdentiKey static site | `SecretStore` reverse index `_index/aliases/<fqdn>` → `{fp, site}` | served by `VanityHostPlug` on Bandit `:4000`, *not* the gateway |
| app name → VM | `Deploy.Registry` JSON `/var/lib/mjolnir/deploy/registry/<slug>.json` | `{app_name, release_snapshot, service_vm_id, url}` |
| VM → local IP | computed: `Mjolnir.Network.allocate_ip(vm_id)` | deterministic SHA256 → `10.200.0.0/10`; not stored |
| app → internal port | `Deploy.BuildPlan.port` (from `Detector`, P0 hardcodes 3000) | baked into `url` string; not stored as structured data |

## Gateway config (`/etc/mjolnir/gateway.toml`)

- **Single TOML file**, resolved by `config::resolve_config_path()` (override:
  `GATEWAY_CONFIG`). No include/merge; `config::load()` reads exactly one path.
- **Hand-maintained today.** No Elixir code generates `[[route]]`/`[[alias]]` entries — the
  `zine` alias was entered manually. (This is a known stopgap; see the local-routing plan.)
- **Hot reload:** `systemctl reload mjolnir-gateway` → SIGHUP → `load()` → atomic `ArcSwap`
  swap of the `RouteTable` (`main.rs:1338-1459`). A parse error keeps the previous config;
  in-flight connections keep their snapshot. Listener addr changes still need a restart.

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

### Known gaps (for automation / custom domains / multi-host)

- No `custom_domain` / `domains` field — the friendly hostname lives only in the gateway
  `[[alias]]`, disconnected from the binding.
- No `host` field — can't tell which physical host a VM is on (needed for local-vs-remote
  routing once there's more than one host).
- `port` is baked into the `url` string, not structured — awkward to template into a route
  backend.
- Write-once on deploy; not reconciled/observed against live VM state.

These gaps are why gateway config is still hand-edited. Closing them lets an Elixir
generator render gateway routes from the binding. See
[`plans/gateway-local-routing.md`](plans/gateway-local-routing.md).
