# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mjolnir is a distributed computational fabric for spawning checkpointable Linux microVMs. It uses Elixir/OTP for orchestration, BTRFS copy-on-write reflinks for instant filesystem cloning, and vsock for host-guest communication.

**Default hypervisor: Cloud Hypervisor v50.0** with virtio-fs + BTRFS subvolumes. Firecracker was removed — it lacked virtio-fs support, which is required for the current storage architecture.

## Current Status

See `docs/plans/current-status.md` for detailed handoff notes.

VMs are fully functional: spawn, exec, kill lifecycle working end-to-end with Cloud Hypervisor v50 + virtio-fs.

### Deployment

- Server: `ssh root@45.76.77.97`
- Deploy via Justfile (preferred): `just deploy`, `just deploy-full`, `just deploy-rootfs`
- Deploy via script: `./scripts/deploy.sh root@45.76.77.97` (add `--agent` for guest agent rebuild, `--rootfs` for disk image)
- Guest agent cross-compile target: `x86_64-unknown-linux-musl`
- `cargo check` fails on macOS for guest agent (tokio-vsock is Linux-only) — this is expected

## Local Control Plane (Justfile)

The Justfile is the primary interface for operating Mjolnir from your Mac. All commands are run locally — VM operations are tunneled through SSH to the server's localhost API.

### Setup

```bash
# 1. Install just (if needed)
brew install just          # macOS
cargo install just         # or via cargo

# 2. Configure your server connection
cp .env.example .env
# Edit .env and set MJOLNIR_HOST=root@45.76.77.97

# 3. Verify (VM/health ops go through the `mj` binary, not just)
mj doctor                  # API reachable + host health (KVM, vsock, forwarding, BTRFS)
```

You can also pass the host inline to server recipes: `just host=root@1.2.3.4 status`

### Command Reference

Run `just --list` for the full list. Commands are grouped into four sections:

**Local Dev** — run directly on Mac, no SSH:

```bash
just compile          # mix compile
just test             # mix test
just format           # mix format
just iex              # iex -S mix
just deps             # mix deps.get
just build-client     # Build TypeScript client
```

**Deploy** — rsync code to server, build release, restart service:

```bash
just deploy           # Code + rebuild guest agent
just deploy-boot      # Code + agent + initramfs
just deploy-rootfs    # Rebuild base rootfs (arch or ubuntu-24.04)
just deploy-runner    # Build + deploy Forgejo runner with VM backend
just deploy-gateway   # Code + rebuild web gateway
just build-ci-image   # Build CI rootfs on server (@base/ci-ubuntu-24.04)
```

**VM Operations** — use the **`mj` binary** (`native/mjolnir_client/`). It talks to the public API with token auth (`mj login` / `mj status`), so it works from anywhere — no SSH tunnel. There are no `just vm-*` recipes; `mj` is the whole VM/snapshot surface:

```bash
mj spawn                               # Spawn a VM (--snapshot <name>, --memory <mb>, --connect)
mj list [--dormant]                    # List running VMs (--dormant also shows parked)
mj info <id>                           # Detailed status
mj exec <id> "uname -a"                # Run a command
mj kill <id> | mj kill --all           # Destroy one VM, or all of them
mj reboot <id> | mj restart <id>       # Hard-reset a wedged guest in place + re-attach
mj url <id>                            # Web gateway URL
mj connect <id>                        # Interactive PTY (WebSocket)
mj message <id> '{"k":"v"}'            # Send a payload in; wakes a dormant VM
mj doctor [<id>] [--fix]               # Health probe (no id = API + host); --fix heals
mj ticket get <id> [--wait]            # Connection ticket (--wait blocks for PTY readiness)
mj snapshot create <id> <name>         # Checkpoint a VM
mj snapshot list                       # List snapshots
mj snapshot show <name>                # Snapshot metadata
mj snapshot rm <name>                  # Delete a snapshot
```

Add `--json` to any reporting command for the raw server response. Run `mj --help` for the full surface (`mj connect`/`mj ssh`/`mj proxy`, `mj config`, `mj forge`, `mj server`).

**Server Management** — SSH into the server:

```bash
just ssh              # Interactive SSH session
just status           # systemctl status mjolnir
just logs             # Follow journald logs (live)
just logs-recent      # Last 100 log lines (configurable: just logs-recent n=500)
just restart          # Restart mjolnir service
just remote-shell     # Attach to remote IEx shell
just debug-vm <id>    # Show TAP interface + routes for a VM
just cleanup-taps     # Remove orphaned TAP interfaces
just server-networking  # Show IP forwarding, NAT rules, TAP interfaces
just bootstrap        # Bootstrap a fresh server
```

### How It Works

The Justfile is for **server operations** — deploy, build, host management — plus the **IdentiKey Sites** recipes. Those Sites recipes still use **SSH-wrapped curl** (`ssh host "curl localhost:4000/..."`) because the API auth bypass only trusts `127.0.0.1`; the SSH tunnel makes curl appear as localhost on the server. VM and snapshot operations are **not** in the Justfile — they live in the `mj` binary, which authenticates to the public API with a bearer token and needs no SSH tunnel.

## Build & Development Commands

These are the raw mix/cargo commands (the Justfile wraps most of these):

```bash
mix deps.get          # Fetch dependencies
mix compile           # Build the project
mix test              # Run unit tests (~320 tests, 0 failures as of 2026-05-13)
mix test --include integration   # Run with real VMs (needs KVM + root on server)
mix test test/mjolnir_test.exs           # Run a single test file
mix test test/mjolnir_test.exs:5         # Run a specific test by line number
mix format            # Format all Elixir code
mix format --check-formatted             # Check formatting without modifying
iex -S mix            # Start interactive console with the application loaded
```

### Guest Agent (Rust)

```bash
cd native/mjolnir_guest_agent && cargo build --release    # Build guest agent
```

The guest agent binary is `mjolnir-agent` and must be cross-compiled for the VM's target architecture (x86_64-unknown-linux-musl for static linking).

**Important: All Rust builds must happen on the server**, not on macOS. The guest agent depends on `tokio-vsock` which is Linux-only — `cargo check` and `cargo build` both fail on macOS. Use the Mjolnir server (`ssh root@45.76.77.97`) as the build server:

```bash
just build-boot-agent           # Cross-compile boot agent on server via SSH
just build-initramfs            # Build initramfs cpio archive on server (depends on build-boot-agent)
just deploy-boot                # Copy boot artifacts to /var/lib/mjolnir/boot/
```

The full guest agent is built as part of `just deploy-full` (which runs `cargo build` on the server via `scripts/deploy.sh --agent`).

### Host Setup (Linux only, requires root)

```bash
sudo ./scripts/bootstrap-host-ubuntu.sh  # Ubuntu/Debian servers
sudo ./scripts/bootstrap-host-arch.sh    # Arch Linux (local dev)
```

Requires Linux with KVM (`/dev/kvm`), a BTRFS filesystem, Cloud Hypervisor v50+, Elixir 1.15+, and Erlang 26+.

## Architecture

### Hypervisor Abstraction

`Mjolnir.Hypervisor` behaviour (8 callbacks: `start_vm`, `configure_vm`, `start_instance`, `pause_instance`, `resume_instance`, `stop_instance`, `cleanup`, `vsock_path`, `process_name`):

- **`Mjolnir.Hypervisor.CloudHypervisor`** — Single `vm.create` PUT with full JSON payload, then `vm.boot`. Uses Unix socket API. Needs PVH-capable kernel (`ch_kernel_path` config). Supports virtio-fs for direct BTRFS subvolume sharing.

Config key: `hypervisor: Mjolnir.Hypervisor.CloudHypervisor` in `config/config.exs`.

### Supervision Tree

```
Mjolnir.Supervisor (one_for_one)
├── Mjolnir.Cleanup          — Sweeps orphan hypervisor processes, stale TAPs, sockets on startup
├── Mjolnir.EventBus          — Pub/sub for VM lifecycle events (:vm_started, :vm_stopped, :vm_dormant)
├── Mjolnir.VMRegistry         — Registry mapping vm_id (UUID) → GenServer PID
├── Mjolnir.DormantRegistry    — ETS table for dormant VM metadata (snapshot name, original config)
├── Mjolnir.VMSupervisor       — DynamicSupervisor spawning VM GenServers on demand
└── Bandit HTTP Server         — Serves Mjolnir.API.Router on port 4000
```

### Core Modules

- **`Mjolnir.VM`** — GenServer managing a single VM's lifecycle (spawn → boot → running → stop/dormant). Each VM is a `:transient` process under the DynamicSupervisor (exits `:normal` on boot failure to prevent restart loops). Public API: `spawn/1`, `exec/3`, `status/1`, `stop/1`, `list/0`, `snapshot/2`, `deliver_message/3`, `handle_done/1`. Boot sequence: clone rootfs → inject guest agent → create TAP → start hypervisor binary → configure via API → boot → wait for guest agent ping → configure guest network → configure identity/SSH/Iroh.

- **`Mjolnir.BTRFS`** — Filesystem operations. Uses `btrfs subvolume snapshot` for instant CoW cloning of base subvolumes (shared into the guest via virtio-fs; no ext4 image). Storage layout: `@base/` (template subvolumes), `@vms/<uuid>/` (per-VM rootfs subvolume), `@snapshots/<name>/` (named snapshot subvolumes).

- **`Mjolnir.CloudHypervisor.Client`** — HTTP client for CH's REST API over Unix socket via `Req`. Endpoints: `vm.create`, `vm.boot`, `vm.pause`, `vm.resume`, `vm.shutdown`, `vm.delete`, `vm.info`.

- **`Mjolnir.CloudHypervisor.Config`** — TypedStruct that builds the CH `vm.create` payload. Key fields: `kernel_path`, `boot_args` (includes `root=myfs rootfstype=virtiofs rw`), `vsock_cid` (unique per VM from MD5 of UUID), `mem_size_mib` (converted to bytes for CH API), `virtiofsd_socket` (vhost-user socket path).

- **`Mjolnir.Cleanup`** — Runs at startup. Finds orphan hypervisor processes via `ps`, kills them. Cleans stale sockets, TAP devices in DOWN state (`mj-*`), and VM directories without running GenServers.

- **`Mjolnir.DormantRegistry`** — ETS-backed registry for VMs that have called `handle_done/1`. Stores snapshot name and original config so dormant VMs can be restored on incoming message.

- **`Mjolnir.EventBus`** — GenServer-based pub/sub. Subscribe to specific VM events or `:all`. Used for lifecycle notifications.

- **`Mjolnir.Network`** — TAP device creation/deletion, IP allocation (hash-based, deterministic), MAC generation, route management. Subnet: 10.0.0.0/8 range.

- **`Mjolnir.Vsock.Connection`** — GenServer managing a persistent vsock connection to a guest VM. Connects via `CONNECT <port>\n` handshake over UDS.

- **`Mjolnir.Vsock.Protocol`** — Wire protocol with channel multiplexing: 1-byte channel ID + 4-byte big-endian length prefix + payload. Channel 0 = JSON control, channels 1-255 = binary PTY streams.

### Forge — Host Config Reconciler (`lib/mjolnir/forge/`)

Declarative host configuration with three-way diff (declared/owned/observed), ownership tracking that makes prune first-class, and a JSON-per-record + ETS store mirroring `Mjolnir.StateStore`. Design: `docs/plans/host-reconcile.md`. Resource kinds: `systemd_unit`, `file`, `sysctl`, `apt_package`, `user`, `ufw_nat`, `iptables`. `:local` transport only (SSH stubbed).

- **`Mjolnir.Forge.Supervisor`** — mounts Store, EventBus, AuditLog, Declarations, HostRegistry, HostSupervisor under `Mjolnir.Supervisor`.
- **`Mjolnir.Forge.Store`** — JSON+ETS records under `forge_state_dir/<host>/<safe_key>.json`. Identity is `{host, kind, resource_id}`. Atomic write+fsync+rename; bad files quarantined.
- **`Mjolnir.Forge.Resource`** — behaviour with `kind/0`, `canonical/1`, `observe_path/1`, `parse_observed/1`, `apply/3`, `delete/2`, `to_declaration/2` (content→DSL block, inverse of the macros), optional `enumerate/1` (host-wide discovery). `Resource.observe/4` and `enumerate/3` dispatch on transport. `enumerable_kinds/0`: systemd_unit/apt_package/user.
- **`Mjolnir.Forge.Canonical`** — sorted-key JSON + SHA-256. No CBOR, no blake3 NIF — hash is for equality only.
- **`Mjolnir.Forge.Diff.compute/3`** — pure 3-way matrix → status entries. Auto-adopts on exact match.
- **`Mjolnir.Forge.Declaration` + `Declarations`** — DSL macros (`systemd_unit/2`, `file/2`, …) accumulating into `@forge_resources`; loader scans `forge/declarations/*.exs` and exposes `for_host/1` / `declared_map/1` / `source_path/3` (which `.exs` a resource came from) / `reload/0`.
- **`Mjolnir.Forge.Authoring`** — writes one `<host>__<kind>__<id>.adopted.exs` per adopted resource (deterministic slug, atomic write, `forge_owned?/1`). Forge only ever edits files it authored; hand-written declarations are never touched.
- **`Mjolnir.Forge.Host`** — per-host worker; `plan/1` + `apply/2` + `diff_one/2` + `adopt/2` + `ignore/2` + `discover/1` are on-demand. `:conflict` and `:unmanaged` never auto-resolve. `auto_apply` defaults to false. Emits `:probe`/`:drift` on plan, `:apply`/`:adopt` on apply, `:ignore` on ignore. adopt refuses hand-managed resources (`:hand_managed`); ignore is sticky across re-plans. `discover/1` enumerates undeclared resources as `:unmanaged`.
- **`Mjolnir.Forge.EventBus`** — `:pg` pub/sub mirroring `Mjolnir.EventBus` (no Phoenix.PubSub). Subscribe `:all` or `{:host, h}`; receive `{:forge_event, event}`.
- **`Mjolnir.Forge.AuditLog`** — GenServer owning an append-only JSONL log at `<forge_state_dir>/_events/audit.jsonl`. Stamps a strictly-monotonic `id` (the SSE resume cursor); `since/1` + `recent/1` for replay. Best-effort durability (no per-line fsync). `_events` is a reserved dir name the Store skips.
- **`Mjolnir.Forge.Events`** — the `Event` struct + `emit/1` (audit-append-then-publish) + JSON/SSE serialization + `probe`/`drift`/`apply_outcome` builders. `:ignore` emitted by `Host.ignore/2`.
- **`Mjolnir.Forge.API`** — Plug forwarded from `Mjolnir.API.Router` at `/api/forge/*`. Endpoints: `GET /hosts`, `POST /hosts`, `GET /plan?host=H`, `POST /apply`, `GET /state`, `GET /discover?host=H`, `GET /diff?host=&kind=&id=`, `POST /adopt` `{host,kind,id}`, `POST /ignore` `{host,kind,id}`, `GET /decl-path?host=&kind=&id=`, `GET /events?since=&limit=`, `GET /events/stream?since=` (SSE, `text/event-stream`, 15s heartbeat).

Justfile shortcuts: `just forge-hosts`, `just forge-plan [host_id]`, `just forge-apply [host_id]`, `just forge-state`, `just forge-events [since] [limit]`, `just forge-events-tail [since]`, `just forge-host-add HOST [transport]`. CLI: `mjolnir forge events [--tail] [--since <id>] [--limit N]`; `mjolnir forge tui [--host self]` (ratatui+crossterm: filterable table, side-by-side diff view, apply/adopt/ignore, `e:edit` declaration in `$EDITOR`, live SSE refresh). No host-wide discovery enumeration for sysctl/iptables/file — those adopt by name.

Sandbox mode: when `:forge_systemd_units_dir` is set to anything other than `/etc/systemd/system`, SystemdUnit writes/removes files but skips all `systemctl` shell-outs. Used by `config/test.exs` and the integration test suite.

### Guest Agent (Rust, `native/mjolnir_guest_agent/`)

Runs inside the VM, listens on vsock port 5000 (VMADDR_CID_ANY). Handles: `exec`, `ping`, `configure_network`, `configure_identity`, `configure_iroh`, `get_iroh_status`. PTY support for interactive sessions via Iroh QUIC.

### Configuration

Config cascades: `config/config.exs` → `config/{dev,test,prod}.exs` → `config/runtime.exs` (env vars).

Key settings: `hypervisor`, `btrfs_root`, `kernel_path`, `ch_kernel_path`, `cloud_hypervisor_bin`, `socket_dir`, `default_vcpus`, `default_memory_mb`, `default_base_image`, `guest_agent_bin`.

Runtime env overrides: `MJOLNIR_BTRFS_ROOT`, `MJOLNIR_SOCKET_DIR`, `MJOLNIR_AUTH_ISSUER`, `MJOLNIR_API_PORT`.

Server kernel path: `/var/lib/mjolnir/vmlinux-ch` (Cloud Hypervisor PVH).

### Data Flow

1. `VM.spawn/1` → UUID generated → CID generated (MD5 hash of UUID, range [3, 0xFFFFFFFF)) → GenServer started under DynamicSupervisor
2. `handle_continue(:boot)` → BTRFS reflink clone → inject guest agent binary → create TAP → Port.open hypervisor binary → wait for API socket → configure VM → boot instance → poll vsock for guest agent → configure guest network/identity/Iroh
3. `VM.exec/3` → persistent `Vsock.Connection` → length-prefixed JSON over UDS → match response by UUID → return stdout or error
4. `VM.stop/1` → GenServer.stop → `terminate/2` → cleanup (kill hypervisor, delete TAP, remove sockets/rootfs)
5. `VM.handle_done/1` → snapshot VM → register in DormantRegistry → stop with `:normal`

### Key Patterns

- VMs looked up via `Registry` with `{:via, Registry, {Mjolnir.VMRegistry, vm_id}}`
- Hypervisor managed as a Port (OS process) — crash isolation is a feature
- Boot failure → `{:stop, :normal, state}` so `:transient` DynamicSupervisor does NOT restart
- Partial boot cleanup via Process dictionary tracking (`Process.put(:boot_partial, ...)`)
- Guest agent auto-injected into rootfs at boot (`inject_guest_agent/1`) when `guest_agent_bin` config is set
- `test/support/vm_case.ex` provides test case template that cleans up orphan VMs
- `elixirc_paths` includes `test/support` only in test env

### Postgres Sidecar

An OTP-managed Postgres instance is supervised under `Mjolnir.Postgres.Supervisor` (children: `Server` → `Bootstrap` → `Migrator` → `Repo`). The Postgres OS process runs as an Erlang Port — no systemd unit, no `pg_ctl` daemon — listening only on a Unix socket. Connections use peer authentication with `pg_ident.conf` mapping the BEAM's OS user to the `mjolnir_admin` (migrations) and `mjolnir_sites` (app reads/writes) DB roles. The bootstrap role owns each schema; service roles get CRUD on their schema only via `ALTER DEFAULT PRIVILEGES` — they cannot DDL.

**Design contract:** filesystem (SecretStore, Sites.Store) is the source of truth for signed envelopes and content-addressed blobs. Postgres holds **derived indexes** (`sites.head_index`, `sites.manifest_index`) that can be rebuilt from disk. Writes go to FS first, then best-effort upsert to PG.

**Controlled by `:pg_enabled`** — false by default (so `mix test` and Macs-without-pg stay green), true in `config/dev.exs` and `config/prod.exs`. Override with `MJOLNIR_PG_ENABLED=true|false`. In prod, postgres drops privileges via `setpriv` to user `mjolnir_pg` (created by the host bootstrap script) because the postgres binary refuses to run as root.

Modules: `lib/mjolnir/postgres/{server,bootstrap,migrator,supervisor,config}.ex`, `lib/mjolnir/repo.ex` (`Mjolnir.Repo` for app, `Mjolnir.Repo.Admin` for migrations only — not supervised). Migrations under `priv/repo/migrations/`. Index modules: `Mjolnir.Sites.HeadIndex`, `Mjolnir.Sites.ManifestIndex`.

### Forgejo Runner — VM-Sandboxed CI (`native/forgejo-runner/`, `lib/mjolnir/runner/`)

Forgejo Actions workflows execute inside Mjolnir microVMs instead of Docker containers. Architecture: a patched fork of the Go `forgejo-runner` binary (managed as an Erlang Port by `Runner.Server`) calls the Mjolnir HTTP API to spawn/exec/stop VMs per job.

- **Go executor**: `native/forgejo-runner/pkg/mjolnir/executor.go` — implements act's `container.Container` interface
- **Elixir supervisor**: `lib/mjolnir/runner/{server,config,supervisor}.ex` — Port lifecycle, feature-flagged via `:runner_enabled`
- **Deploy**: `just deploy-runner` (clones upstream, patches, builds, installs systemd service)
- **Labels**: `ubuntu-24.04:mjolnir:ubuntu-24.04` — `runs-on: ubuntu-24.04` routes to VM backend
- **Server paths**: binary at `/usr/local/bin/forgejo-runner-mjolnir`, state at `/var/lib/mjolnir/runner/`
- **Logs**: `journalctl -u forgejo-runner`

Multi-VirtioFS support (`lib/mjolnir/virtiofs.ex`) allows mounting additional host directories (e.g., repo) read-only into CI VMs via `extra_mounts` API parameter. Paths validated against `allowed_mount_prefixes` config.

### Syslog Infrastructure (`lib/mjolnir/syslog/`)

Universal syslog-over-vsock transport for VM log output. The guest agent (`src/syslog.rs`) binds `/dev/log` inside the VM and forwards messages as framed binary on vsock channel 2.

- **`Syslog.Listener`** — receives channel 2 data from VMs, buffers partial lines, dispatches to Router
- **`Syslog.Parser`** — RFC 3164 parsing (priority, facility, severity, tag, message)
- **`Syslog.Router`** — routes parsed messages to sinks (`:eventbus`, `:logger`)
- **`Syslog.Supervisor`** — conditional on `config :mjolnir, :syslog, enabled: true`
- Tests: `test/mjolnir/syslog/parser_test.exs` (18 tests)

### Test Harness

See `docs/plans/test-harness-spec.md` for the full specification.

- **Unit tests** (`mix test`): ~613 tests, async, no infrastructure needed, run on macOS
- **Integration tests** (`mix test --include integration`): Need KVM + root on server
- **Postgres tests** (`mix test --include postgres`): Need `postgres` + `initdb` + `pg_isready` on PATH. Each test brings up its own ephemeral instance under `/tmp`.
- **E2E tests** (`mix test --include e2e`): Future — full API lifecycle
- Tags: `:integration`, `:postgres`, `:cloud_hypervisor`, `:snapshot`, `:network`, `:slow`


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
