# Forge — Host Config Reconciler

Forge is Mjolnir's declarative host-configuration system: you declare the desired
state of host resources (systemd units, files, sysctls, firewall rules, packages,
users) in Elixir DSL files, and Forge reconciles the live host toward them with a
three-way diff, ownership tracking, and an append-only audit trail.

> **Design doc:** [`plans/host-reconcile.md`](plans/host-reconcile.md) is the original
> design. This file documents the **as-built** system, which diverges from the plan in
> its persistence layer (JSON+ETS / SHA-256, *not* the originally-sketched SQLite/CBOR).
> Code: `lib/mjolnir/forge/`.

## Why Forge exists

A microVM host accumulates imperative setup — NAT rules, IP forwarding, systemd
services, kernel sysctls. Shell-script provisioning can *create* that state but can
never *detect drift* ("someone SSH'd in and edited the unit") or safely *prune* what
it no longer owns. Forge makes host config a reconciled resource: desired vs owned vs
observed, with prune as a first-class outcome rather than an afterthought.

## Core idea: the three-way diff

Every resource is compared along three axes, and the pair `(owned?, observed?, matches?)`
classifies it into one status:

- **declared** — what the DSL says should exist.
- **owned** — what Forge recorded creating on its last apply (the Store).
- **observed** — what's actually on the host right now (probed live).

`Mjolnir.Forge.Diff.compute/3` is a pure function producing one status per resource:

| Status | Meaning | Auto-applies? |
|---|---|---|
| `:converged` | declared == observed | — (nothing to do) |
| `:new` | declared, not yet on host | yes |
| `:drifted` | declared, on host, but differs | yes |
| `:missing` | declared + owned, vanished from host | yes |
| `:prune` | owned but no longer declared | yes |
| `:conflict` | declared + observed, differ, **not owned** | **no — needs human** |
| `:unmanaged` | on host, not declared, not owned | **no — needs human** |

`:conflict` and `:unmanaged` never auto-resolve — Forge refuses to clobber state it
didn't create. On an exact declared==observed match with no ownership record, Forge
**auto-adopts** (records ownership) rather than reapplying.

## Resource model

`Mjolnir.Forge.Resource` is a behaviour each kind implements:

- `kind/0` — the resource type atom.
- `canonical/1` — deterministic form for equality (feeds the hash).
- `observe_path/1` + `parse_observed/1` — how to read the live host.
- `apply/3` / `delete/2` — idempotent converge / prune (safe to call in any state).
- `to_declaration/2` — inverse of the DSL macro (content → DSL block), used by adoption.
- `enumerate/1` *(optional)* — host-wide discovery of undeclared instances.

**Built-in kinds** (`lib/mjolnir/forge/resource/`): `systemd_unit`, `file`, `sysctl`,
`apt_package`, `user`, `ufw_nat`, `iptables`. Identity of any resource is the tuple
`{host, kind, resource_id}`.

Only `systemd_unit`, `apt_package`, and `user` support host-wide `enumerate` (used by
`discover`). `file`, `sysctl`, `iptables`, `ufw_nat` adopt by name, not by enumeration.

### Canonicalization

`Mjolnir.Forge.Canonical` produces sorted-key JSON + SHA-256. The hash is **for equality
only** — no CBOR, no blake3 NIF. Two resources are "the same" iff their canonical hashes
match.

## Declarations (the DSL)

`Mjolnir.Forge.Declaration` provides macros (`systemd_unit/2`, `file/2`, `sysctl/2`, …)
that accumulate into a module's `@forge_resources`. `Mjolnir.Forge.Declarations` loads
`forge/declarations/*.exs` and exposes `for_host/1`, `declared_map/1`, `source_path/3`
(which `.exs` a resource came from), and `reload/0`.

Two authorship modes coexist safely:

- **Hand-written** declarations — never touched by Forge.
- **Adopted** declarations — `Mjolnir.Forge.Authoring` writes one
  `<host>__<kind>__<id>.adopted.exs` per adopted resource (deterministic slug, atomic
  write). Forge only ever edits files it authored (`forge_owned?/1`); hand-written files
  are off-limits.

## Persistence & events

- **`Mjolnir.Forge.Store`** — JSON-per-record + ETS mirror at
  `forge_state_dir/<host>/<safe_key>.json`. Atomic write+fsync+rename; corrupt files are
  quarantined, never fatal. Mirrors the `Mjolnir.StateStore` pattern used elsewhere.
- **`Mjolnir.Forge.AuditLog`** — append-only JSONL at `<forge_state_dir>/_events/audit.jsonl`.
  Each event gets a strictly-monotonic `id` that doubles as the SSE resume cursor;
  `since/1` + `recent/1` replay it. Best-effort durability (no per-line fsync). `_events`
  is a reserved dir name the Store skips.
- **`Mjolnir.Forge.EventBus`** — `:pg`-based pub/sub (no Phoenix.PubSub), mirroring
  `Mjolnir.EventBus`. Subscribe `:all` or `{:host, h}`; receive `{:forge_event, event}`.
- **`Mjolnir.Forge.Events`** — the `Event` struct + `emit/1` (audit-append-then-publish)
  + JSON/SSE serialization, with `probe`/`drift`/`apply_outcome` builders.

## Supervision & the per-host worker

`Mjolnir.Forge.Supervisor` (mounted under `Mjolnir.Supervisor`) starts:

```
Mjolnir.Forge.Supervisor
├── Store           — JSON+ETS resource records
├── EventBus        — :pg pub/sub for reconciliation events
├── AuditLog        — append-only JSONL + replay cursor
├── Declarations    — loads forge/declarations/*.exs
├── HostRegistry    — host_id → Host pid
└── HostSupervisor  — DynamicSupervisor spawning per-host Host workers
```

**`Mjolnir.Forge.Host`** is the per-host worker. Its operations are **on-demand**, not a
tight loop:

- `plan/1` — probe + three-way diff for every declared resource (emits `:probe`/`:drift`).
- `apply/2` — converge the given keys (emits `:apply`/`:adopt`).
- `diff_one/2` — single-resource diff.
- `adopt/2` — record ownership of an exact match (refuses `:hand_managed` resources).
- `ignore/2` — sticky suppression across re-plans (emits `:ignore`).
- `discover/1` — enumerate undeclared resources as `:unmanaged`.

`auto_apply` defaults to **false**. `:conflict` and `:unmanaged` never auto-resolve;
`ignore` is sticky.

## HTTP API & tooling

`Mjolnir.Forge.API` is a Plug forwarded from `Mjolnir.API.Router` at `/api/forge/*`:

`GET /hosts`, `POST /hosts`, `GET /plan?host=`, `POST /apply`, `GET /state`,
`GET /discover?host=`, `GET /diff?host=&kind=&id=`, `POST /adopt`, `POST /ignore`,
`GET /decl-path?host=&kind=&id=`, `GET /events?since=&limit=`,
`GET /events/stream?since=` (SSE, `text/event-stream`, 15s heartbeat).

- **Justfile:** `just forge-hosts`, `forge-plan [host]`, `forge-apply [host]`,
  `forge-state`, `forge-events [since] [limit]`, `forge-events-tail [since]`,
  `forge-host-add HOST [transport]`.
- **CLI:** `mjolnir forge events [--tail] [--since <id>] [--limit N]`.
- **TUI:** `mjolnir forge tui [--host self]` (ratatui + crossterm): filterable table,
  side-by-side diff, apply/adopt/ignore, `e:edit` a declaration in `$EDITOR`, live SSE refresh.

## Transport & sandbox mode

- Transport is **`:local`** today (SSH is stubbed). The forward direction is
  **Forge-over-vsock**: reconcile a guest VM's run-state through the guest agent's `exec`
  channel (see "Relationship to Deploy").
- **Sandbox mode:** when `:forge_systemd_units_dir` is set to anything other than
  `/etc/systemd/system`, `SystemdUnit` writes/removes unit files but skips all `systemctl`
  shell-outs. Used by `config/test.exs` and the integration suite so tests need no root.

## Relationship to Deploy

Forge and `Mjolnir.Deploy` are **separate today** but converging by design. Deploy's P0
installs a service VM's systemd unit imperatively (shell heredoc over vsock `exec`) — a
deliberate stopgap. The deploy roadmap's **gge.4 / P2** replaces that with
**Forge-over-vsock**: the VM's run-state becomes a set of Forge *resources*, so a deployed
app's config gains the same drift-detection and reconvergence that host config already
has. The design intent (`plans/initiatives/mjolnir-deploy.md`) states it plainly:
*"Forge is a component of deploy, not its frame"* — the snapshot builder is the frame;
Forge reconciles the final run-state.

The [gateway route generator](plans/gateway-local-routing.md) is another future Forge
consumer: today `Mjolnir.Gateway.Routes` writes `/etc/mjolnir/gateway.d/apps.toml` and
reloads directly, but its natural home is a Forge-managed `file` resource + reload, so
gateway routing converges and drifts like every other host resource instead of being a
parallel bespoke reconciler.

## Multi-host direction

Forge is built host-keyed (`{host, kind, resource_id}`, per-host `Host` workers, a
`HostRegistry`) so a fleet is a natural extension: the same declare→observe→diff→apply
loop runs per host, driven over a per-host transport. The `:local`-only transport is the
current limit, not an architectural one.
