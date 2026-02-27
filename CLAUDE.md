# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mjolnir is a distributed computational fabric for spawning checkpointable Linux microVMs. It uses Elixir/OTP for orchestration, BTRFS copy-on-write reflinks for instant filesystem cloning, and vsock for host-guest communication.

**Default hypervisor: Cloud Hypervisor v50.0** (transitioned from Firecracker in Feb 2026). Firecracker support is retained behind the `Mjolnir.Hypervisor` behaviour but Cloud Hypervisor is the active default.

## Current Status & Known Issues

See `docs/plans/current-status.md` for detailed handoff notes including open bugs.

**Open issue**: Cloud Hypervisor `vm.create` returns 400 Bad Request. The payload structure appears correct per the CH v50 OpenAPI spec, but CH rejects it. A debug `Logger.info` line has been added to `lib/mjolnir/cloud_hypervisor/client.ex:create_vm/2` to print the payload — deploy and test to see the exact JSON being sent. The rootfs clone, TAP creation, and CH process startup all succeed; only the API call to configure the VM fails.

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
mix test              # Run unit tests (101 tests, 0 failures as of 2026-02-26)
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

### Host Setup (Linux only, requires root)

```bash
sudo ./scripts/bootstrap-host.sh
```

Requires Linux with KVM (`/dev/kvm`), a BTRFS filesystem, Cloud Hypervisor v50+, Elixir 1.15+, and Erlang 26+.

## Architecture

### Hypervisor Abstraction

Both hypervisors implement `Mjolnir.Hypervisor` behaviour (8 callbacks: `start_vm`, `configure_vm`, `start_instance`, `pause_instance`, `resume_instance`, `stop_instance`, `cleanup`, `vsock_path`, `process_name`):

- **`Mjolnir.Hypervisor.CloudHypervisor`** (default) — Single `vm.create` PUT with full JSON payload, then `vm.boot`. Uses Unix socket API. Needs PVH-capable kernel (`ch_kernel_path` config).
- **`Mjolnir.Hypervisor.Firecracker`** — Multi-step PUT sequence (boot-source, drives, machine-config, vsock, network, then InstanceStart). Uses Unix socket API.

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

- **`Mjolnir.CloudHypervisor.Config`** — TypedStruct that builds the CH `vm.create` payload. Key fields: `kernel_path`, `boot_args` (includes `root=/dev/vda rw`), `vsock_cid` (unique per VM from MD5 of UUID), `mem_size_mib` (converted to bytes for CH API).

- **`Mjolnir.Cleanup`** — Runs at startup. Finds orphan hypervisor processes via `ps`, kills them. Cleans stale sockets, TAP devices in DOWN state (`mj-*`), and VM directories without running GenServers.

- **`Mjolnir.DormantRegistry`** — ETS-backed registry for VMs that have called `handle_done/1`. Stores snapshot name and original config so dormant VMs can be restored on incoming message.

- **`Mjolnir.EventBus`** — GenServer-based pub/sub. Subscribe to specific VM events or `:all`. Used for lifecycle notifications.

- **`Mjolnir.Network`** — TAP device creation/deletion, IP allocation (hash-based, deterministic), MAC generation, route management. Subnet: 10.0.0.0/8 range.

- **`Mjolnir.Vsock.Connection`** — GenServer managing a persistent vsock connection to a guest VM. Connects via `CONNECT <port>\n` handshake over UDS.

- **`Mjolnir.Vsock.Protocol`** — Wire protocol with channel multiplexing: 1-byte channel ID + 4-byte big-endian length prefix + payload. Channel 0 = JSON control, channels 1-255 = binary PTY streams.

### Guest Agent (Rust, `native/mjolnir_guest_agent/`)

Runs inside the VM, listens on vsock port 5000 (VMADDR_CID_ANY). Handles: `exec`, `ping`, `configure_network`, `configure_identity`, `configure_iroh`, `get_iroh_status`. PTY support for interactive sessions via Iroh QUIC.

### Configuration

Config cascades: `config/config.exs` → `config/{dev,test,prod}.exs` → `config/runtime.exs` (env vars).

Key settings: `hypervisor`, `btrfs_root`, `kernel_path`, `ch_kernel_path`, `cloud_hypervisor_bin`, `socket_dir`, `default_vcpus`, `default_memory_mb`, `default_base_image`, `guest_agent_bin`.

Runtime env overrides: `MJOLNIR_BTRFS_ROOT`, `MJOLNIR_SOCKET_DIR`, `MJOLNIR_AUTH_ISSUER`, `MJOLNIR_API_PORT`.

Server kernel paths: `/var/lib/mjolnir/vmlinux` (Firecracker), `/var/lib/mjolnir/vmlinux-ch` (Cloud Hypervisor PVH).

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

### Test Harness

See `docs/plans/test-harness-spec.md` for the full specification.

- **Unit tests** (`mix test`): 101 tests, async, no infrastructure needed, run on macOS
- **Integration tests** (`mix test --include integration`): Need KVM + root on server
- **E2E tests** (`mix test --include e2e`): Future — full API lifecycle
- Tags: `:integration`, `:cloud_hypervisor`, `:snapshot`, `:network`, `:slow`
