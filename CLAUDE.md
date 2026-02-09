# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mjolnir is a distributed computational fabric for spawning checkpointable Linux shells in Firecracker microVMs. It uses Elixir/OTP for orchestration, BTRFS copy-on-write reflinks for instant filesystem cloning, and vsock for host-guest communication. The project is in early development (Phase 1).

## Build & Development Commands

```bash
mix deps.get          # Fetch dependencies
mix compile           # Build the project
mix test              # Run all tests
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
sudo BTRFS_DEVICE=/dev/sdb ./scripts/setup-host.sh
```

Requires Linux with KVM (`/dev/kvm`), a spare disk for BTRFS, Firecracker 1.5+, Elixir 1.15+, and Erlang 26+.

## Architecture

### Supervision Tree

```
Mjolnir.Supervisor (one_for_one)
├── Mjolnir.VMRegistry    — Registry mapping vm_id (UUID) → GenServer PID
└── Mjolnir.VMSupervisor  — DynamicSupervisor spawning VM GenServers on demand
```

### Core Modules

- **`Mjolnir.VM`** — GenServer managing a single VM's lifecycle (spawn → boot → running → stop). Each VM is a transient process under the DynamicSupervisor. Public API: `spawn/1`, `exec/3`, `status/1`, `stop/1`, `list/0`. Boot sequence: clone rootfs → start firecracker binary → configure via REST API → start instance → wait for guest agent ping.

- **`Mjolnir.BTRFS`** — Filesystem operations. Uses `cp --reflink=auto` for instant CoW cloning of ext4 images stored on a BTRFS partition. Storage layout: `@base/` (template images), `@vms/<uuid>/` (per-VM rootfs), `@snapshots/` (future).

- **`Mjolnir.Firecracker.Client`** — HTTP client talking to Firecracker's REST API over Unix domain sockets via `Req`. Configures boot source, drives, machine config, vsock, and controls instance lifecycle (start/pause/resume).

- **`Mjolnir.Firecracker.Config`** — TypedStruct that builds Firecracker API payloads from VM configuration.

- **`Mjolnir.Vsock.Connection`** — GenServer managing a single vsock connection to a guest VM. Connects to Firecracker's vsock proxy UDS, sends `CONNECT 5000\n`, then switches to async mode for request/response matching by UUID.

- **`Mjolnir.Vsock.Protocol`** — Wire protocol: 4-byte big-endian length prefix + JSON body. Message types: `exec`/`exec_response`, `ping`/`pong`.

### Guest Agent (Rust, `native/mjolnir_guest_agent/`)

Runs inside the VM, listens on vsock port 5000 (VMADDR_CID_ANY). Receives length-prefixed JSON commands, executes them via `sh -c`, and returns stdout/stderr/exit_code. Uses tokio for async I/O with tokio-vsock.

### Configuration

Config cascades: `config/config.exs` → `config/{dev,test,prod}.exs` → `config/runtime.exs` (env vars).

Key settings: `btrfs_root`, `kernel_path`, `firecracker_bin`, `socket_dir`, `default_vcpus`, `default_memory_mb`, `default_base_image`.

Runtime env overrides: `MJOLNIR_BTRFS_ROOT`, `MJOLNIR_SOCKET_DIR`.

Test environment uses separate paths (`/var/lib/mjolnir/btrfs-test`, `/tmp/mjolnir-test`).

### Data Flow

1. `VM.spawn/1` → UUID generated → GenServer started under DynamicSupervisor
2. GenServer `init` → `handle_continue(:boot)` → BTRFS reflink clone → Port.open firecracker binary → Req HTTP calls to configure VM → start instance → poll vsock for guest agent readiness
3. `VM.exec/3` → creates ephemeral `Vsock.Connection` GenServer → sends length-prefixed JSON over UDS → matches response by request UUID → returns stdout or error tuple
4. `VM.stop/1` → GenServer.stop → `terminate/2` → Port.close firecracker, cleanup sockets and rootfs files

### Key Patterns

- VMs are looked up via `Registry` with `{:via, Registry, {Mjolnir.VMRegistry, vm_id}}` tuples
- Firecracker is managed as a Port (OS process), not an NIF — crash isolation is a feature
- `test/support/vm_case.ex` provides a test case template that cleans up orphan VMs after each test
- `elixirc_paths` includes `test/support` only in test env
