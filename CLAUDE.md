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

# 3. Verify
just health                # Should return {"status":"ok"}
```

You can also pass the host inline: `just host=root@1.2.3.4 health`

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
just deploy           # Code only
just deploy-full      # Code + rebuild guest agent
just deploy-rootfs    # Code + rebuild rootfs disk image
```

**VM Operations** — manage VMs via the HTTP API (SSH-tunneled):

```bash
just vm-spawn                          # Spawn a new VM
just vm-spawn-from my-snapshot         # Spawn from a snapshot
just vm-list                           # List running VMs
just vm-info <id>                      # Get VM details
just vm-exec <id> "uname -a"          # Execute a command in a VM
just vm-stop <id>                      # Stop a VM
just vm-stop-all                       # Stop all running VMs
just vm-ticket <id>                    # Get Iroh connection ticket
just vm-await-pty <id>                 # Wait for PTY readiness
just vm-message <id> '{"key":"val"}'   # Send a message to a VM
just snap-create <id> my-snap          # Snapshot a VM
just snap-list                         # List all snapshots
just snap-info my-snap                 # Get snapshot metadata
just snap-delete my-snap               # Delete a snapshot
just dormant                           # List dormant VMs
```

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

All VM/snapshot commands use **SSH-wrapped curl**: `ssh host "curl localhost:4000/..."`. This is required because the API auth bypass only works for connections from `127.0.0.1` — direct curl from your Mac would get `401`. The SSH tunnel makes curl appear as localhost on the server.

For commands that need JSON request bodies (`vm-exec`, `vm-spawn-from`, `snap-create`, `vm-message`), local `jq` constructs the JSON safely and pipes it through SSH to curl's stdin (`-d @-`), avoiding shell quoting issues.

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

- **`Mjolnir.BTRFS`** — Filesystem operations. Uses `cp --reflink=auto` for instant CoW cloning of ext4 images on BTRFS. Storage layout: `@base/` (template images), `@vms/<uuid>/` (per-VM rootfs), `@snapshots/<name>/` (named snapshots).

- **`Mjolnir.CloudHypervisor.Client`** — HTTP client for CH's REST API over Unix socket via `Req`. Endpoints: `vm.create`, `vm.boot`, `vm.pause`, `vm.resume`, `vm.shutdown`, `vm.delete`, `vm.info`.

- **`Mjolnir.CloudHypervisor.Config`** — TypedStruct that builds the CH `vm.create` payload. Key fields: `kernel_path`, `boot_args` (includes `root=myfs rootfstype=virtiofs rw`), `vsock_cid` (unique per VM from MD5 of UUID), `mem_size_mib` (converted to bytes for CH API), `virtiofsd_socket` (vhost-user socket path).

- **`Mjolnir.Cleanup`** — Runs at startup. Finds orphan hypervisor processes via `ps`, kills them. Cleans stale sockets, TAP devices in DOWN state (`mj-*`), and VM directories without running GenServers.

- **`Mjolnir.DormantRegistry`** — ETS-backed registry for VMs that have called `handle_done/1`. Stores snapshot name and original config so dormant VMs can be restored on incoming message.

- **`Mjolnir.EventBus`** — GenServer-based pub/sub. Subscribe to specific VM events or `:all`. Used for lifecycle notifications.

- **`Mjolnir.Network`** — TAP device creation/deletion, IP allocation (hash-based, deterministic), MAC generation, route management. Subnet: 10.0.0.0/8 range.

- **`Mjolnir.Vsock.Connection`** — GenServer managing a persistent vsock connection to a guest VM. Connects via `CONNECT <port>\n` handshake over UDS.

- **`Mjolnir.Vsock.Protocol`** — Wire protocol with channel multiplexing: 1-byte channel ID + 4-byte big-endian length prefix + payload. Channel 0 = JSON control, channels 1-255 = binary PTY streams.

### Forge — Host Config Reconciler (`lib/mjolnir/forge/`)

Declarative host configuration with three-way diff (declared/owned/observed), ownership tracking that makes prune first-class, and a JSON-per-record + ETS store mirroring `Mjolnir.StateStore`. Design: `docs/plans/host-reconcile.md`. v0 supports `systemd_unit` and `file` kinds, `:local` transport only (SSH stubbed).

- **`Mjolnir.Forge.Supervisor`** — mounts Store, Declarations, HostRegistry, HostSupervisor under `Mjolnir.Supervisor`.
- **`Mjolnir.Forge.Store`** — JSON+ETS records under `forge_state_dir/<host>/<safe_key>.json`. Identity is `{host, kind, resource_id}`. Atomic write+fsync+rename; bad files quarantined.
- **`Mjolnir.Forge.Resource`** — behaviour with `kind/0`, `canonical/1`, `observe_path/1`, `parse_observed/1`, `apply/3`, `delete/2`. `Resource.observe/4` dispatches on transport (`:local | :ssh`).
- **`Mjolnir.Forge.Canonical`** — sorted-key JSON + SHA-256. No CBOR, no blake3 NIF — hash is for equality only.
- **`Mjolnir.Forge.Diff.compute/3`** — pure 3-way matrix → status entries. Auto-adopts on exact match.
- **`Mjolnir.Forge.Declaration` + `Declarations`** — DSL macros (`systemd_unit/2`, `file/2`) accumulating into `@forge_resources`; loader scans `forge/declarations/*.exs` and exposes `for_host/1` / `declared_map/1` / `reload/0`.
- **`Mjolnir.Forge.Host`** — per-host worker; `plan/1` + `apply/2` are on-demand. `:conflict` and `:unmanaged` never auto-resolve. `auto_apply` defaults to false.
- **`Mjolnir.Forge.API`** — Plug forwarded from `Mjolnir.API.Router` at `/api/forge/*`. v0 endpoints: `GET /hosts`, `POST /hosts`, `GET /plan?host=H`, `POST /apply`, `GET /state`.

Justfile shortcuts: `just forge-hosts`, `just forge-plan [host_id]`, `just forge-apply [host_id]`, `just forge-state`, `just forge-host-add HOST [transport]`.

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

### Test Harness

See `docs/plans/test-harness-spec.md` for the full specification.

- **Unit tests** (`mix test`): ~325 tests, async, no infrastructure needed, run on macOS
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
