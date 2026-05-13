# Mjolnir Host Reconciler ("Forge")

**Status**: Design (2026-05-12)
**Owner**: Duke
**Predecessor**: `durability.md` (same architecture, host-scope)
**Subsystem name**: `Mjolnir.Forge` — the thing that bashes config into the right shape.
**CLI surface**: `mjolnir forge <subcommand>` (extends the existing Rust CLI).

---

## Goals

1. **Single source of truth for host configuration.** Declarations in repo → reconciler converges the host. No more `ssh root@host vim /etc/...`.
2. **Drift is observable and removable.** Unknown systemd units, hand-edited drop-ins, mismatched ufw rules — all surfaced as a structured diff.
3. **Removal is first-class.** Deleting a declaration removes the resource on next apply (this is what shell scripts and Ansible cannot do).
4. **One-host today, fleet tomorrow.** Architecture is multi-host from day one; the v0 just happens to point at one box.
5. **Probe escape hatches for non-file resources.** UFW NAT, sysctl-live, package state — anything that isn't a file gets a custom `probe/1`.
6. **TUI for the diff, fzf for the lists.** Visual diff is the killer feature; fzf-fuzzy-pick is the keyboard-velocity feature. Both shipped in the existing Rust CLI.

## Non-goals (for now)

- Replacing `bootstrap-host-ubuntu.sh` wholesale. The reconciler runs *after* base bootstrap; OS install + apt packages stay in shell.
- Imperative orchestration ("install A then B then restart C in this order"). Use systemd `After=`/`Requires=` for ordering. The reconciler converges *resources*, not workflows.
- Cross-host coordination (rolling updates, leader election, draining). Add when we have >3 hosts.
- A new DSL. Declarations are plain Elixir modules. If we outgrow that, port later.
- Standalone `forge` binary. Forge ships as part of `mjolnir.service`; the user-facing CLI is `mjolnir forge`.

## Design principles

1. **Three-way diff is load-bearing.** Every resource has `declared` (what config says), `owned` (what we created last apply, in SQLite), `observed` (what's on disk now). Every cell of the Venn diagram is a distinct status; the matrix is the entire state machine.
2. **Hash everything, materialize lazily.** A resource's identity is `(kind, id)`; its state is `blake3(canonical_cbor(content))`. The reconciler compares hashes; only the TUI materializes content for display.
3. **Ownership is the prune signal.** "Did we create this last time?" is the only question that distinguishes "remove it" from "leave it alone". Without ownership tracking, removal is impossible.
4. **Both observe paths.** File-backed by default (cheap, universal). Probe-per-kind escape hatch (full power). Resource kinds declare which they use.
5. **Apply is idempotent destroy-then-create.** Every `apply/1` is safe to call in any state — no pre-check branching in the apply path.
6. **Adopt-or-ignore for unmanaged.** Anything observed-but-unowned is surfaced, never silently overwritten. The user picks: adopt (copy into declarations + take ownership), ignore (mark in SQLite as `ignored`), or delete (manual).
7. **Thin client, fat controller.** Reconciler runs in BEAM on the Mjolnir server. CLI on the user's Mac is a thin HTTP client — same pattern as `mjolnir vm-spawn`. All state, all probes, all watches live server-side.

---

## Architecture

```
Mjolnir.Supervisor (one_for_one)                        ← existing
├── Mjolnir.Cleanup                                     ← existing
├── Mjolnir.EventBus                                    ← existing
├── Mjolnir.VMRegistry / DormantRegistry / VMSupervisor ← existing
├── Mjolnir.Forge.Supervisor                            ← NEW
│   ├── Mjolnir.Forge.Repo               — Ecto + ecto_sqlite3
│   ├── Mjolnir.Forge.Declarations       — loads/watches declarations/*.exs (FileSystem lib)
│   ├── Mjolnir.Forge.HostSupervisor (DynamicSupervisor)
│   │   └── Mjolnir.Forge.Host (GenServer, one per managed host)
│   │        ├── transport (local | ssh)
│   │        ├── reconcile loop (Process.send_after, configurable)
│   │        └── per-resource probers
│   ├── Mjolnir.Forge.EventBus           — drift notifications (Phoenix.PubSub)
│   └── Mjolnir.Forge.API                — mounted under Mjolnir.API.Router at /api/forge/*
└── Bandit                                              ← existing
```

```
Mac (Rust CLI)                              Server (Elixir)
─────────────────                           ─────────────────
mjolnir forge plan        ──SSH+curl──▶     GET  /api/forge/plan
mjolnir forge apply       ──SSH+curl──▶     POST /api/forge/apply
mjolnir forge diff X      ──SSH+curl──▶     GET  /api/forge/diff/X
mjolnir forge adopt --fzf ──SSH+curl──▶     GET  /api/forge/unmanaged
                                              ↓ pick via fzf locally ↓
                          ──SSH+curl──▶     POST /api/forge/adopt
mjolnir forge tui (ratatui) ◀──polling──▶   GET  /api/forge/state
```

The Rust CLI never knows what SQLite is, never probes a host, never parses a systemd unit. It renders. The Elixir controller owns state, ownership, observation, and apply.

### Why this fits Mjolnir

- **Same pattern as VM ops.** `mjolnir vm-spawn` already SSH-tunnels curl to `localhost:4000`. Forge endpoints inherit the localhost auth bypass for free.
- **Same supervision shape as `VMSupervisor`.** `Host` workers are `:transient` — one crashing host doesn't take out the rest.
- **Same durability story.** `Mjolnir.Forge.Repo` lives under `/var/lib/mjolnir/forge/state.db`; if BEAM dies, systemd restarts and SQLite WAL recovers. Mirrors `Mjolnir.StateStore` for VMs.
- **Multi-server falls out of BEAM.** When fleet grows, spawn more `Host` workers. libcluster + Phoenix.PubSub gives HA controllers when we want them.

---

## Storage

### SQLite schema (lives at `/var/lib/mjolnir/forge/state.db`)

```elixir
# resources — one row per (host, kind, id)
schema "resources" do
  field :host,           :string                # "mjolnir@45.76.77.97" | "self"
  field :kind,           :string                # "systemd_unit"
  field :resource_id,    :string                # "mjolnir.service"
  field :declared_hash,  :binary                # blake3 of canonical cbor, or nil
  field :owned_hash,     :binary                # what we last applied
  field :observed_hash,  :binary                # last probe result
  field :content_blob,   :binary                # cbor of declared content (for diff)
  field :status,         Ecto.Enum, values: [
    :converged, :drifted, :missing, :new, :prune, :unmanaged, :conflict, :ignored
  ]
  field :applied_at,     :utc_datetime
  field :observed_at,    :utc_datetime
  timestamps()
end

# events — append-only audit log
schema "events" do
  field :host,           :string
  field :kind,           :string
  field :resource_id,    :string
  field :action,         Ecto.Enum, values: [
    :create, :update, :delete, :adopt, :ignore, :probe, :error
  ]
  field :before_hash,    :binary
  field :after_hash,     :binary
  field :diff_blob,      :binary                # cbor diff for display
  field :error,          :string
  timestamps()
end

# host_meta — connection info, last-seen, agent version
schema "host_meta" do
  field :host,           :string, primary_key: true
  field :transport,      Ecto.Enum, values: [:local, :ssh]
  field :connection,     :map                   # {addr, user, ssh_key_path, ...}
  field :last_seen_at,   :utc_datetime
  field :agent_version,  :string                # if running an on-host agent later
  timestamps()
end
```

Indexes: `(host)`, `(host, status)`, `(host, kind, resource_id)` unique. SQLite WAL mode. Repo configured with `pool_size: 1` (SQLite is single-writer; serialize via the Repo).

### Wire format (CBOR)

Used by `/api/forge/*` endpoints and (later) by inter-controller sync. Deterministic encoding (canonical CBOR per RFC 8949 §4.2.1) means `hash(cbor(x)) == hash(cbor(x))` byte-for-byte across machines.

```
┌─ envelope ──────────────────────────┐
│ {                                   │
│   v: 1,                             │
│   host: "mjolnir@...",              │
│   ts: 1715472000,                   │
│   kind: "snapshot" | "delta",       │
│   resources: [                      │
│     { kind, id, content, hash },    │
│     ...                             │
│   ]                                 │
│ }                                   │
└─────────────────────────────────────┘
```

HTTP responses use CBOR by default with `?fmt=json` for human inspection via curl. Libraries: `:cbor` hex package, blake3 via `:b3` NIF.

---

## Resource model

### Behaviour

```elixir
defmodule Mjolnir.Forge.Resource do
  @callback kind() :: String.t()
  @callback id(content :: term()) :: String.t()
  @callback canonical(content :: term()) :: binary()        # → CBOR
  @callback observe_path(id :: String.t()) :: {:file, Path.t()} | :probe
  @callback probe(host :: Mjolnir.Forge.Host.t(), id :: String.t()) ::
              {:ok, content :: term()} | :missing | {:error, term()}
  @callback apply(host :: Mjolnir.Forge.Host.t(), content :: term()) :: :ok | {:error, term()}
  @callback delete(host :: Mjolnir.Forge.Host.t(), id :: String.t()) :: :ok | {:error, term()}
end
```

### Built-in kinds (v0–v1)

| Kind | Observe | Notes |
|---|---|---|
| `systemd_unit` | `:file` (`/etc/systemd/system/<id>`) | apply → `cp` + `systemctl daemon-reload` + `enable` |
| `systemd_dropin` | `:file` (`/etc/systemd/system/<unit>.d/<name>.conf`) | same |
| `sysctl` | `:probe` (`sysctl -n <key>`) | apply → write `/etc/sysctl.d/99-forge-<key>.conf` + `sysctl -p` |
| `ufw_nat` | `:probe` (parse `before.rules`) | apply → patch `*nat` block, `ufw reload` |
| `iptables_chain` | `:probe` (`iptables-save -t <table>`) | for live rules outside ufw |
| `file` | `:file` | generic — content + mode + owner |
| `apt_package` | `:probe` (`dpkg-query -W`) | install / hold / remove |
| `user` | `:probe` (`getent passwd`) | uid, gid, shell, home |

Each kind is ~50–150 LOC. New kinds drop in without touching the core.

### Declaration syntax (Elixir DSL)

Lives in the repo at `forge/declarations/<host>.exs`, loaded into the BEAM by `Mjolnir.Forge.Declarations`.

```elixir
# forge/declarations/mjolnir_host.exs
defmodule Forge.Declarations.MjolnirHost do
  use Mjolnir.Forge.Declaration, host: "mjolnir@45.76.77.97"

  systemd_unit "mjolnir.service" do
    source File.read!("systemd/mjolnir.service")
    enabled true
    state   :running
  end

  systemd_unit "mjolnir-gateway.service" do
    source File.read!("systemd/mjolnir-gateway.service")
    enabled true
    state   :running
  end

  ufw_nat "vm_subnet" do
    source_cidr "10.192.0.0/10"
    out_iface   "enp1s0"
  end

  sysctl "net.ipv4.ip_forward", value: "1"
end
```

`use Mjolnir.Forge.Declaration` accumulates resources into module attributes; `Mjolnir.Forge.Declarations.load/0` evaluates each `.exs` and registers the resulting list. File-watched via the `:file_system` hex package — edits in `forge/declarations/**` trigger a reload + reconcile cycle.

---

## The diff matrix

| declared | owned | observed | status | action |
|---|---|---|---|---|
| ✓ | ✓ | matches | `:converged` | none |
| ✓ | ✓ | differs | `:drifted` | re-apply |
| ✓ | ✓ | missing | `:missing` | re-apply (recreate) |
| ✓ | ✗ | ✗ | `:new` | create |
| ✓ | ✗ | ✓ | `:conflict` | prompt: adopt or fail |
| ✗ | ✓ | ✓ | `:prune` | delete |
| ✗ | ✓ | ✗ | (already gone) | clear ownership |
| ✗ | ✗ | ✓ | `:unmanaged` | prompt: adopt / ignore / delete |

Rendered as a single table in TUI / CLI. Color: green (converged), yellow (drifted/missing/new/prune), red (conflict), blue (unmanaged), grey (ignored).

---

## HTTP API (`/api/forge/*`)

All endpoints negotiate CBOR/JSON via `Accept` header; default CBOR, `?fmt=json` for curl. Auth: same localhost bypass as VM endpoints (so SSH-tunneled curl works without tokens).

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/api/forge/state` | Full resource table for all hosts (paginated). |
| `GET`  | `/api/forge/state?host=H&kind=K&status=S` | Filtered view. |
| `GET`  | `/api/forge/plan` | Force re-observe + return current diff. |
| `POST` | `/api/forge/apply` | Body: `{resources: [...] \| :all, dry_run: bool}`. Returns per-resource result. |
| `GET`  | `/api/forge/diff/:host/:kind/:id` | Side-by-side payload: declared, observed, unified-diff lines. |
| `POST` | `/api/forge/adopt` | Body: `{host, kind, id, target_module}` — writes declaration file, marks owned. |
| `POST` | `/api/forge/ignore` | Body: `{host, kind, id}` — sets `:ignored`. |
| `GET`  | `/api/forge/events?since=...&host=...` | Audit log tail. |
| `GET`  | `/api/forge/events/stream` | Server-Sent Events (SSE) for live TUI / `forge events --tail`. |
| `GET`  | `/api/forge/hosts` | Managed hosts list. |
| `POST` | `/api/forge/hosts` | Body: `{host, transport, connection}` — add a host. |

All bodies are CBOR or JSON; SSE frames are JSON for `text/event-stream` compatibility.

---

## CLI (`mjolnir forge`)

The existing Rust CLI grows a `forge` subcommand. New module: `src/forge/` mirroring `src/api.rs` / `src/connect.rs`.

```
mjolnir forge plan                    # diff only, no changes
mjolnir forge apply                   # converge everything not :ignored or :conflict
mjolnir forge apply --only systemd    # filter by kind
mjolnir forge apply --resource X.service
mjolnir forge diff <resource>         # side-by-side
mjolnir forge adopt                   # interactive — fzf-pick unmanaged → POST /adopt
mjolnir forge ignore <resource>       # POST /ignore
mjolnir forge probe                   # POST /plan (no apply)
mjolnir forge tui                     # launch ratatui interactive view
mjolnir forge events --tail           # stream the audit log (SSE)
mjolnir forge hosts                   # list managed hosts (fzf-pickable when piped)
```

Standard exit codes: `0` clean, `1` drift detected (CI-gateable), `2` errors.

### fzf integration (Rust-side)

fzf is **opt-in** — every list-emitting command supports `--fzf` (or auto-detects when `FZF_DEFAULT_COMMAND` is set or `stdout.is_terminal()` and `which::which("fzf").is_ok()`). When enabled, the command shells out to `fzf` via `std::process::Command`, streams tab-separated rows to its stdin, and parses the selection from stdout.

```bash
mjolnir forge plan --fzf            # pick a resource → opens `forge diff <picked>`
mjolnir forge adopt                 # always uses fzf if available; else numbered prompt
mjolnir forge events --fzf          # pick an event → expands into full diff blob
mjolnir forge hosts --fzf           # pick a host → scopes subsequent commands
```

Pure-Rust fallback (`dialoguer::Select` or a hand-rolled numbered prompt) when fzf isn't on `$PATH`. ~80 LOC in `src/forge/fzf.rs`. The TUI doesn't shell to fzf — it has its own filter view bound to `/`. fzf is for one-shot CLI flows.

---

## TUI (ratatui, Rust)

Rendered by the existing CLI binary using the `ratatui` crate (the Rust kin of Ratatouille — same model, native to our existing toolchain). Data fetched via polling `GET /api/forge/state` every 2s, plus SSE subscription to `/api/forge/events/stream` for live updates.

### Main view

```
┌─ mjolnir forge — mjolnir@45.76.77.97 ───── [3 drifted, 2 unmanaged] ─┐
│ STATUS       KIND            ID                                      │
│ ● converged  systemd_unit    mjolnir-gateway.service                 │
│ ▲ drifted    systemd_unit    mjolnir.service                         │
│ ▲ drifted    ufw_nat         vm_subnet                               │
│ ▲ missing    sysctl          net.ipv4.ip_forward                     │
│ ◆ unmanaged  systemd_unit    forgejo.service                         │
│ ◆ unmanaged  systemd_dropin  mjolnir.service.d/override.conf         │
│ ✓ converged  apt_package     cloud-hypervisor                        │
│ — ignored    file            /etc/motd                               │
└──────────────────────────────────────────────────────────────────────┘
  /filter  d:diff  a:apply  A:apply-all  o:adopt  i:ignore  r:refresh  q:quit
```

### Diff view (after `d`)

```
┌─ mjolnir.service ─ declared ─────┬─ observed ───────────────────────┐
│ [Unit]                           │ [Unit]                           │
│ Description=Mjolnir MicroVM Fa.. │ Description=Mjolnir MicroVM Fa.. │
│ After=network.target local-fs.t..│ After=network.target local-fs.t..│
│ -Wants=mjolnir-loopback.service  │                                  │
│  StartLimitIntervalSec=60        │  StartLimitIntervalSec=60        │
│ ...                              │ ...                              │
└──────────────────────────────────┴──────────────────────────────────┘
  e:edit-decl  a:apply  o:overwrite-decl-from-observed  q:back
```

Side-by-side diff via `similar` crate (Myers). `o` is "the on-host version is what I actually want, copy it back into declarations/" — turns the TUI into a learning loop for adopting drift you decide to keep. `e` opens `$EDITOR` against the declaration file locally; on save, the new contents POST through `/api/forge/adopt` with a write-through.

### Library notes

- **ratatui** ≥ 0.26 — `Table` widget for the main view, custom widget for split-pane diff.
- **crossterm** for terminal control (cross-platform).
- **similar** for diffs, **chrono** for timestamps, **reqwest** (already a transitive dep via the API client) for HTTP, **eventsource-client** for SSE.

---

## Reconcile loop

```elixir
# Mjolnir.Forge.Host.handle_info(:reconcile, state)
def handle_info(:reconcile, state) do
  declared = Mjolnir.Forge.Declarations.for_host(state.host)
  observed = observe_all(state, declared)
  owned    = Mjolnir.Forge.Repo.owned_for(state.host)

  diff = Mjolnir.Forge.Diff.compute(declared, owned, observed)
  Mjolnir.Forge.Repo.upsert_resources(state.host, diff)
  Mjolnir.Forge.EventBus.broadcast({:diff, state.host, diff})

  if state.auto_apply, do: apply_safe_actions(state, diff)
  Process.send_after(self(), :reconcile, state.interval_ms)
  {:noreply, state}
end
```

`apply_safe_actions/2` only acts on `:new`, `:drifted`, `:missing`, `:prune`. `:conflict` and `:unmanaged` always require human ack — the reconciler will not auto-resolve them.

### Observation strategy

```elixir
defp observe_one(host, kind_mod, id) do
  case kind_mod.observe_path(id) do
    {:file, path} ->
      case Mjolnir.Forge.Host.read_file(host, path) do
        {:ok, bytes}      -> {:present, bytes}
        {:error, :enoent} -> :missing
        {:error, e}       -> {:error, e}
      end

    :probe ->
      kind_mod.probe(host, id)
  end
end
```

File-backed is preferred (cheap, uniform). Probes are slower but sometimes the only option. Both paths produce the same shape — `{:present, content} | :missing | {:error, _}` — so the diff engine doesn't care which was used.

### Transport

- **`:local`** — `host == "self"`. Direct `File.read!`, `System.cmd`. Used for reconciling the Mjolnir server itself.
- **`:ssh`** — multiplexed SSH (`ControlMaster`-style) via `:erlexec` or shelling to `ssh`. One persistent connection per host, file reads via `cat`, probes via `ssh host '<cmd>'`. v1 uses raw SSH; v2 may replace with an on-host agent that speaks CBOR over the gateway.

---

## v0 milestone

**One host (`self` = the Mjolnir server), one kind (`systemd_unit`), file-backed only, CLI only (no TUI), no fleet plumbing.**

```
mjolnir forge plan                 # → table of converged/drifted/unmanaged systemd units
mjolnir forge apply                # → reconciles them
mjolnir forge adopt --fzf          # → pick unmanaged units, write to forge/declarations/
```

This alone fixes the four drift items found in the 2026-05-11 audit:
1. The `mjolnir-loopback.service` ghost reference (declared without it → drift detected → re-apply removes it).
2. The `override.conf` (unmanaged → adopt or delete via prompt).
3. `forgejo*` units (unmanaged → adopt into a `Forge.Declarations.Forgejo` module).
4. NAT subnet inconsistency comes in v1 with `ufw_nat` kind.

### Sizing

| Component | LOC estimate |
|---|---|
| `Mjolnir.Forge.Supervisor` + `Repo` + migrations | ~120 |
| `Mjolnir.Forge.Host` GenServer | ~150 |
| `Mjolnir.Forge.Resource` behaviour + `SystemdUnit` impl | ~180 |
| `Mjolnir.Forge.Diff` engine | ~120 |
| `Mjolnir.Forge.Declarations` loader + DSL macros | ~150 |
| `Mjolnir.Forge.API` (Plug routes) | ~120 |
| Rust CLI: `src/forge/{mod,api,plan,apply,adopt,fzf}.rs` | ~400 |
| Tests | ~400 |

**~1,600 LOC total**, doable in 2–3 focused days. The TUI adds ~600 LOC of Rust (v1).

### v0 → v1 deltas

- Add `sysctl`, `ufw_nat`, `iptables_chain`, `file`, `apt_package`, `user` kinds.
- Add ratatui TUI (`mjolnir forge tui`).
- Add SSE event stream + `mjolnir forge events --tail`.
- Add a second host (the laptop, for testing) — proves SSH transport without proving multi-host coordination.

### v1 → v2 deltas

- Optional on-host agent (Rust static binary) so the controller doesn't need SSH per probe. Ships state via CBOR over the gateway.
- libcluster + Phoenix.PubSub for HA controllers.
- Web UI on top of the same `/api/forge/*` endpoints.

---

## Open questions

1. **Where do declaration files live?** Suggest `forge/declarations/<host>.exs` referencing `systemd/*.service` and similar for content. Keeps unit files diffable as files. Alternative: colocate under `config/` to match Elixir conventions.
2. **Forge as new top-level app or nested supervisor?** Going with nested under `Mjolnir.Supervisor` (option A). If it grows independent of Mjolnir's lifecycle later, extract to an umbrella app.
3. **Secret handling.** `gateway.env`, cookies, tokens. Out of scope for v0 — keep secrets in `EnvironmentFile=` paths that are themselves declared as `file` resources with `mode: 0600` and content sourced from `1Password`/`age`/whatever later.
4. **Drift detection cadence.** `:reconcile` interval defaults to 60s. Cheap because file-backed observation hashes only changed files (use `inotify` via `:file_system` later if needed).
5. **`mjolnir forge apply` blast radius.** Default to dry-run + confirm on first apply per session, with `--yes` for automation. Never auto-apply on first observation of a new host.
6. **What does "ownership" mean for files we didn't write but match exactly?** If `declared_hash == observed_hash` but `owned_hash` is nil — adopt automatically? Or treat as `:conflict`? Suggest auto-adopt-on-exact-match; require prompt only when content differs.
7. **Where does `self` host reconciliation get its declarations?** Same file structure as any other host. The Mjolnir server reconciles itself by reading `forge/declarations/mjolnir_host.exs` from the deployed code at `/opt/mjolnir`. The deploy step that ships code also ships declarations.

---

## Out-of-scope (deferred / never)

- **Cross-host orchestration.** Add when fleet > 3 hosts or we have a real "this restart needs to drain that load balancer first" requirement.
- **Replacing systemd.** Forge declares units; systemd runs them. We are not building a process supervisor.
- **Replacing apt.** `apt_package` reconciles installed-or-not; package builds remain Debian's job.
- **Web UI.** Wait until the TUI exists and we have evidence we want a browser version.
- **Generic config templating (Jinja-like).** Plain Elixir string interpolation in declarations is enough until proven otherwise.
- **Reconciling non-Mjolnir hosts (e.g., laptop dotfiles).** That use case wants a one-shot escript, which is a different shape of program. Revisit if it becomes a recurring pain.
