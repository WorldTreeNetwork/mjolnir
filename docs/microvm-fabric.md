# Mjolnir MicroVM Execution Fabric
## Distributed Checkpointable Linux Shell Spawning System

### Executive Summary

This document specifies a distributed computational fabric where:
- **Compute units** are Cloud Hypervisor microVMs (Linux shells with full `apt` access)
- **State persistence** leverages BTRFS copy-on-write for instant VM cloning and filesystem snapshots
- **Orchestration** is handled by Elixir/OTP for actor-based concurrency, supervision trees, and distributed message-passing
- **AI agents** (e.g., Claude Code) run natively inside microVMs with full system access

VMs can be cloned instantly (BTRFS reflink), their filesystems snapshotted, and migrated between nodes. Full orthogonal persistence (memory + CPU state) is a future option via Cloud Hypervisor's native pause/resume—see [orthogonal-persistence.md](orthogonal-persistence.md).

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MJOLNIR CONTROL PLANE                            │
│                    (Elixir/OTP Cluster)                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │ Scheduler   │  │ Registry    │  │ Checkpoint  │                 │
│  │ GenServer   │  │ GenServer   │  │ Coordinator │                 │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                 │
│         │                │                │                         │
│  ┌──────┴────────────────┴────────────────┴──────┐                 │
│  │              Distributed Supervisor            │                 │
│  │         (cross-node fault tolerance)           │                 │
│  └───────────────────────┬───────────────────────┘                 │
└──────────────────────────┼──────────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   HOST NODE 1   │ │   HOST NODE 2   │ │   HOST NODE N   │
│  ┌───────────┐  │ │  ┌───────────┐  │ │  ┌───────────┐  │
│  │ Node Agent│  │ │  │ Node Agent│  │ │  │ Node Agent│  │
│  │ (Elixir)  │  │ │  │ (Elixir)  │  │ │  │ (Elixir)  │  │
│  └─────┬─────┘  │ │  └─────┬─────┘  │ │  └─────┬─────┘  │
│        │        │ │        │        │ │        │        │
│  ┌─────┴─────┐  │ │  ┌─────┴─────┐  │ │  ┌─────┴─────┐  │
│  │   Cloud   │  │ │  │   Cloud   │  │ │  │   Cloud   │  │
│  │Hypervisor │  │ │  │Hypervisor │  │ │  │Hypervisor │  │
│  └─────┬─────┘  │ │  └─────┬─────┘  │ │  └─────┬─────┘  │
│        │        │ │        │        │ │        │        │
│  ┌─────┴─────┐  │ │  ┌─────┴─────┐  │ │  ┌─────┴─────┐  │
│  │   BTRFS   │  │ │  │   BTRFS   │  │ │  │   BTRFS   │  │
│  │  Storage  │  │ │  │  Storage  │  │ │  │  Storage  │  │
│  └───────────┘  │ │  └───────────┘  │ │  └───────────┘  │
│                 │ │                 │ │                 │
│  ┌───┐ ┌───┐    │ │  ┌───┐ ┌───┐   │ │  ┌───┐ ┌───┐    │
│  │VM │ │VM │    │ │  │VM │ │VM │   │ │  │VM │ │VM │    │
│  │ 1 │ │ 2 │... │ │  │ 3 │ │ 4 │...│ │  │ 5 │ │ 6 │... │
│  └───┘ └───┘    │ │  └───┘ └───┘   │ │  └───┘ └───┘    │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

---

## 2. Core Components

### 2.1 Cloud Hypervisor MicroVM Layer

Cloud Hypervisor provides:
- **~125ms boot time** (vs minutes for traditional VMs)
- **Low memory overhead** per microVM
- **Minimal attack surface** (reduced device model)
- **Pause/resume** of memory + device state
- **virtio-fs** for direct BTRFS subvolume sharing with guests

#### MicroVM Configuration

Cloud Hypervisor uses a single `vm.create` PUT with a full JSON payload, then `vm.boot`. The kernel must be PVH-capable.

```json
{
  "cpus": { "boot_vcpus": 2, "max_vcpus": 2 },
  "memory": { "size": 536870912, "shared": true },
  "kernel": { "path": "/var/lib/mjolnir/vmlinux-ch" },
  "cmdline": { "args": "console=hvc0 root=myfs rootfstype=virtiofs rw" },
  "fs": [
    {
      "tag": "myfs",
      "socket": "/tmp/mjolnir/virtiofsd/{vm_id}.sock"
    }
  ],
  "net": [
    {
      "tap": "mj-{tap_id}",
      "mac": "{generated_mac}"
    }
  ],
  "vsock": {
    "cid": "{vm_cid}",
    "socket": "/tmp/mjolnir/vsock/{vm_id}.sock"
  }
}
```

#### Kernel Selection

Cloud Hypervisor requires a PVH-capable kernel with VIRTIO_FS built in. The production kernel is at `/var/lib/mjolnir/vmlinux-ch`.

| Kernel Version | Use Case | Notes |
|----------------|----------|-------|
| 5.10 LTS | Legacy (deprecated) | Used with Firecracker; lacks VIRTIO_FS |
| 6.1 LTS | Minimum for CH | VIRTIO_FS support, good BTRFS features |
| 6.12+ | Current production | PVH + VIRTIO_FS built-in; used on server |

**Recommendation**: 6.12+ with PVH and VIRTIO_FS compiled in—required for Cloud Hypervisor + virtio-fs.

#### Base Image Selection

| Distro | Size | Pros | Cons |
|--------|------|------|------|
| **Debian 12** | ~300MB | Minimal, stable, apt-native, no cruft | Slightly older packages |
| Ubuntu 22.04 | ~500MB | Better docs, more tested | Snap pollution, larger |
| Alpine 3.19 | ~50MB | Tiny, fast boot | musl libc breaks some software |

**Decision**: **Debian 12 (Bookworm)** as default base. Minimal, stable, same apt as Ubuntu but leaner. Alpine available for specialized lightweight workloads where musl compatibility is verified.

### 2.2 BTRFS Storage Layer

BTRFS provides the checkpointing foundation via copy-on-write semantics. Cloud Hypervisor exposes the VM rootfs via **virtio-fs**, which means the guest mounts a host directory directly—no block device image required. This eliminates the ext4-on-BTRFS workaround that was needed with Firecracker (legacy).

- **Direct subvolume sharing**: BTRFS subvolumes are mounted into the guest via virtiofsd
- **Instant cloning**: BTRFS subvolume snapshots (`btrfs subvolume snapshot`) for ~1ms CoW subvolume creation regardless of filesystem size
- **Snapshot flexibility**: Multiple checkpoint strategies available

```
/var/lib/mjolnir/btrfs/
├── @base/                    # Base OS subvolumes (immutable directories)
│   └── ubuntu-24.04/         # ~300MB Ubuntu 24.04 rootfs directory
├── @vms/                     # Per-VM subvolume directories
│   └── {vm_id}/              # CoW clone of base subvolume
└── @snapshots/               # Named snapshots
    └── {snapshot_name}/      # BTRFS subvolume snapshot of a VM subvolume
```

#### BTRFS Subvolumes + virtio-fs (Current Architecture)

Cloud Hypervisor exposes a host directory to the guest via a virtiofsd socket. The guest boots with `root=myfs rootfstype=virtiofs rw`, mounting the host BTRFS subvolume directly as its root filesystem.

This solves the old block-device constraint entirely: BTRFS subvolumes are directory trees, and virtio-fs is designed to share exactly that.

```bash
# Clone base subvolume for new VM (instant CoW via BTRFS subvolume snapshot)
btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@base/ubuntu-24.04 \
  /var/lib/mjolnir/btrfs/@vms/{vm_id}

# Start virtiofsd to expose the subvolume to the guest
virtiofsd --socket-path=/tmp/mjolnir/virtiofsd/{vm_id}.sock \
  --shared-dir=/var/lib/mjolnir/btrfs/@vms/{vm_id} \
  --cache=auto

# Snapshot a running VM's rootfs (BTRFS subvolume snapshot, ~1ms metadata operation)
btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@vms/{vm_id} \
  /var/lib/mjolnir/btrfs/@snapshots/{snapshot_name}

# Restore from snapshot
btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@snapshots/{snapshot_name} \
  /var/lib/mjolnir/btrfs/@vms/{vm_id}
```

#### Checkpoint/Restore Strategy

We use **filesystem-only checkpoints** via BTRFS subvolume snapshots:

```bash
# Snapshot a VM's rootfs (instant CoW subvolume snapshot, ~1ms metadata operation)
btrfs subvolume snapshot @vms/{vm_id} @snapshots/{snapshot_name}

# Restore from snapshot
btrfs subvolume snapshot @snapshots/{snapshot_name} @vms/{vm_id}
```

This captures workspace state (files, installed packages, project data) but **not** running process state (memory, CPU registers). For our current use cases—workspace backup, VM cloning, cross-host transfer—this is sufficient.

**Future option**: Cloud Hypervisor supports native pause/resume for true memory+CPU snapshots. See [orthogonal-persistence.md](orthogonal-persistence.md) for details on when we might need this.

#### Compression Strategy

```bash
# Mount options for optimal AI workload performance
mount -o compress=zstd:3,noatime,ssd,discard=async /dev/sda1 /var/lib/mjolnir/btrfs
```

- `zstd:3` - Good compression ratio with low CPU overhead
- `noatime` - Reduce write amplification
- `ssd` - Enable SSD optimizations
- `discard=async` - Background TRIM

### 2.3 Elixir/OTP Orchestration Layer

The orchestration layer leverages OTP's battle-tested distributed systems primitives:

#### Supervision Tree Structure

```elixir
defmodule Mjolnir.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Cluster membership & discovery
      {Mjolnir.Cluster.Manager, []},
      
      # Registry for VM processes
      {Registry, keys: :unique, name: Mjolnir.VMRegistry},
      
      # Global VM scheduler
      {Mjolnir.Scheduler, []},
      
      # Per-node VM supervisor (dynamic children)
      {DynamicSupervisor, strategy: :one_for_one, name: Mjolnir.VMSupervisor},
      
      # Checkpoint coordinator
      {Mjolnir.Checkpoint.Coordinator, []},
      
      # Channel router (π-calculus channels)
      {Mjolnir.Channel.Router, []},
      
      # Metrics & telemetry
      {Mjolnir.Telemetry.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Mjolnir.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### VM GenServer

```elixir
defmodule Mjolnir.VM do
  use GenServer, restart: :transient
  require Logger

  defstruct [
    :id,
    :hypervisor_pid,
    :vsock,
    :state,           # :booting | :running | :paused | :checkpointing | :migrating
    :config,
    :btrfs_subvol,
    :checkpoint_history,
    :channels         # Map of channel_name => channel_pid
  ]

  # Client API
  
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config.id))
  end

  def spawn_shell(vm_id, command) do
    GenServer.call(via_tuple(vm_id), {:spawn_shell, command})
  end

  def checkpoint(vm_id, opts \\ []) do
    GenServer.call(via_tuple(vm_id), {:checkpoint, opts}, :infinity)
  end

  def migrate(vm_id, target_node) do
    GenServer.call(via_tuple(vm_id), {:migrate, target_node}, :infinity)
  end

  def attach_channel(vm_id, channel_name, channel_pid) do
    GenServer.call(via_tuple(vm_id), {:attach_channel, channel_name, channel_pid})
  end

  # Server Callbacks
  
  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    
    state = %__MODULE__{
      id: config.id,
      state: :booting,
      config: config,
      checkpoint_history: [],
      channels: %{}
    }
    
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    with {:ok, btrfs_subvol} <- setup_btrfs_subvol(state.config),
         {:ok, ch_config} <- generate_ch_config(state.config, btrfs_subvol),
         {:ok, ch_pid} <- start_cloud_hypervisor(ch_config),
         {:ok, vsock} <- connect_vsock(state.id) do

      new_state = %{state |
        hypervisor_pid: ch_pid,
        vsock: vsock,
        btrfs_subvol: btrfs_subvol,
        state: :running
      }
      
      Logger.info("VM #{state.id} booted successfully")
      {:noreply, new_state}
    else
      {:error, reason} ->
        Logger.error("Failed to boot VM #{state.id}: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:checkpoint, opts}, _from, state) do
    with {:ok, mem_snapshot} <- pause_and_snapshot_memory(state),
         {:ok, fs_snapshot} <- snapshot_btrfs(state.btrfs_subvol, opts),
         :ok <- maybe_resume(state, opts) do
      
      checkpoint = %{
        id: generate_checkpoint_id(),
        timestamp: DateTime.utc_now(),
        memory_path: mem_snapshot,
        fs_snapshot: fs_snapshot
      }
      
      new_state = %{state | 
        checkpoint_history: [checkpoint | state.checkpoint_history]
      }
      
      {:reply, {:ok, checkpoint}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:migrate, target_node}, _from, state) do
    with {:ok, checkpoint} <- do_checkpoint(state, pause: true),
         :ok <- transfer_checkpoint(checkpoint, target_node),
         :ok <- Mjolnir.Remote.restore_vm(target_node, state.config, checkpoint) do
      
      # Self-terminate after successful migration
      {:stop, :normal, :ok, state}
    else
      {:error, reason} -> 
        resume_vm(state)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:spawn_shell, command}, _from, state) do
    result = execute_via_vsock(state.vsock, command)
    {:reply, result, state}
  end

  # Private functions
  
  defp via_tuple(id), do: {:via, Registry, {Mjolnir.VMRegistry, id}}

  defp setup_btrfs_subvol(config) do
    base_image = config.base_image || "ubuntu-24.04"
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@base", base_image])
    dest = Path.join([btrfs_root, "@vms", config.id])

    with {_, 0} <- System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      {:ok, dest}
    else
      {err, _} -> {:error, {:snapshot_failed, err}}
    end
  end

  # ... additional private functions
end
```

#### Distributed Channel Router

Implements π-calculus channels across the fabric:

```elixir
defmodule Mjolnir.Channel.Router do
  use GenServer
  
  # Channels are identified by {name, scope}
  # scope can be :local | :cluster | {:vm, vm_id} | {:org, org_id}
  
  defstruct [
    :channels,           # %{channel_id => channel_state}
    :subscriptions,      # %{channel_id => [subscriber_pids]}
    :remote_routes       # %{channel_id => node()}
  ]

  def create_channel(name, opts \\ []) do
    GenServer.call(__MODULE__, {:create, name, opts})
  end

  def send_message(channel_id, message) do
    GenServer.cast(__MODULE__, {:send, channel_id, message})
  end

  def subscribe(channel_id, handler) do
    GenServer.call(__MODULE__, {:subscribe, channel_id, handler})
  end

  # π-calculus: channel passing
  def pass_channel(from_channel, to_channel, channel_to_pass) do
    GenServer.call(__MODULE__, {:pass, from_channel, to_channel, channel_to_pass})
  end

  @impl true
  def handle_cast({:send, channel_id, message}, state) do
    case Map.get(state.remote_routes, channel_id) do
      nil ->
        # Local delivery
        deliver_local(channel_id, message, state)
      node ->
        # Remote delivery
        :rpc.cast(node, __MODULE__, :deliver_local, [channel_id, message])
    end
    {:noreply, state}
  end

  def deliver_local(channel_id, message, state \\ nil) do
    state = state || :sys.get_state(__MODULE__)
    
    for subscriber <- Map.get(state.subscriptions, channel_id, []) do
      send(subscriber, {:channel_message, channel_id, message})
    end
  end
end
```

---

## 3. Checkpointing System

Mjolnir uses **filesystem-only checkpoints**—we snapshot the VM's rootfs (BTRFS subvolume directory) via `btrfs subvolume snapshot`. This captures workspace state but not running process memory.

For full VM state snapshots (memory + CPU + devices), see [orthogonal-persistence.md](orthogonal-persistence.md). We defer this complexity until live migration or VM forking becomes a requirement.

### 3.1 Snapshot Operations

```elixir
defmodule Mjolnir.BTRFS do
  @moduledoc """
  Filesystem snapshot operations using BTRFS subvolume snapshots.
  """

  @doc """
  Snapshot a VM's rootfs subvolume. VM should be stopped or quiesced for consistency.
  """
  def snapshot(vm_id, snapshot_name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", vm_id])
    dest = Path.join([btrfs_root, "@snapshots", snapshot_name])

    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      {_, 0} -> {:ok, dest}
      {err, _} -> {:error, {:snapshot_failed, err}}
    end
  end

  @doc """
  Restore a VM's rootfs from a named snapshot. VM must be stopped.
  """
  def restore(vm_id, snapshot_name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@snapshots", snapshot_name])
    dest = Path.join([btrfs_root, "@vms", vm_id])

    with :ok <- File.rm_rf(dest),
         {_, 0} <- System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      :ok
    else
      {err, _} -> {:error, {:restore_failed, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clone a VM's rootfs subvolume to create a new VM. Source VM should be stopped.
  """
  def clone_vm(source_vm_id, target_vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", source_vm_id])
    dest = Path.join([btrfs_root, "@vms", target_vm_id])

    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      {_, 0} -> {:ok, dest}
      {err, _} -> {:error, {:clone_failed, err}}
    end
  end

  @doc """
  List named snapshots.
  """
  def list_snapshots do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    snapshot_dir = Path.join([btrfs_root, "@snapshots"])

    case File.ls(snapshot_dir) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end
end
```

### 3.2 Cross-Node Transfer

For migrating VMs between hosts, we use `btrfs send/receive` for efficient incremental transfer:

```elixir
defmodule Mjolnir.Migration do
  @moduledoc """
  Cold migration of VMs between nodes.
  VM is stopped, filesystem transferred, then started on target.
  """

  def migrate(vm_id, target_node) do
    with :ok <- Mjolnir.VM.stop(vm_id),
         {:ok, _} <- transfer_rootfs(vm_id, target_node),
         {:ok, _} <- start_on_target(vm_id, target_node) do
      cleanup_local(vm_id)
      :ok
    end
  end

  defp transfer_rootfs(vm_id, target_node) do
    # For now, simple rsync over SSH/Tailscale
    # Future: btrfs send/receive for incremental transfer
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", vm_id])

    # Transfer via rsync (or btrfs send in future)
    cmd = "rsync -az #{source}/ #{target_node}:#{source}/"
    System.cmd("sh", ["-c", cmd])
  end
end
```

---

## 4. AI Agent Integration

### 4.1 Agent Execution Environment

Each AI agent runs in its own microVM with:
- Full Ubuntu/Debian environment with `apt`
- Network access (configurable isolation)
- Workspace directory (persisted via BTRFS)
- Channel-based communication with orchestrator

```elixir
defmodule Mjolnir.Agent do
  use GenServer

  defstruct [
    :id,
    :vm_id,
    :type,          # :claude_code | :custom | :sandbox
    :workspace,
    :channels,
    :execution_state
  ]

  def spawn_claude_agent(opts) do
    config = %{
      id: generate_agent_id(),
      base_image: "ubuntu-22.04-ai",
      vcpus: opts[:vcpus] || 4,
      memory_mb: opts[:memory_mb] || 4096,
      workspace: opts[:workspace] || "/workspace",
      init_script: """
      #!/bin/bash
      curl -fsSL https://raw.githubusercontent.com/anthropics/claude-code/main/install.sh | sh
      claude --api-key-file /secrets/anthropic.key
      """
    }
    
    {:ok, vm_id} = Mjolnir.VM.spawn(config)
    
    # Create communication channels
    {:ok, stdin_ch} = Mjolnir.Channel.create("agent.#{config.id}.stdin")
    {:ok, stdout_ch} = Mjolnir.Channel.create("agent.#{config.id}.stdout")
    {:ok, control_ch} = Mjolnir.Channel.create("agent.#{config.id}.control")
    
    Mjolnir.VM.attach_channel(vm_id, :stdin, stdin_ch)
    Mjolnir.VM.attach_channel(vm_id, :stdout, stdout_ch)
    Mjolnir.VM.attach_channel(vm_id, :control, control_ch)
    
    {:ok, %__MODULE__{
      id: config.id,
      vm_id: vm_id,
      type: :claude_code,
      channels: %{stdin: stdin_ch, stdout: stdout_ch, control: control_ch}
    }}
  end

  def send_prompt(agent, prompt) do
    Mjolnir.Channel.send(agent.channels.stdin, {:prompt, prompt})
  end

  def checkpoint_agent(agent) do
    Mjolnir.VM.checkpoint(agent.vm_id)
  end

  def restore_agent(checkpoint_id) do
    # Restore VM and reconnect channels
    {:ok, vm_id} = Mjolnir.Checkpoint.restore(checkpoint_id)
    # ... rebuild agent struct
  end
end
```

### 4.2 Agent Workspace Management

Agent workspaces live inside the VM's BTRFS subvolume, exposed to the guest via virtio-fs. When agents need persistent workspaces that survive VM restarts, use the VM's rootfs snapshot capabilities.

```elixir
defmodule Mjolnir.Agent.Workspace do
  @moduledoc """
  Manages agent workspaces via VM rootfs snapshots.
  Workspaces live inside the VM's BTRFS subvolume directory and can be
  cloned/snapshotted using BTRFS subvolume snapshots.
  """

  def snapshot_vm_rootfs(vm_id, name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", vm_id])
    dest = Path.join([btrfs_root, "@snapshots", name])

    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      {_, 0} -> {:ok, dest}
      {err, _} -> {:error, {:snapshot_failed, err}}
    end
  end

  def clone_vm(source_vm_id, target_vm_id) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@vms", source_vm_id])
    dest = Path.join([btrfs_root, "@vms", target_vm_id])

    # Instant CoW clone via BTRFS subvolume snapshot
    case System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      {_, 0} -> {:ok, dest}
      {err, _} -> {:error, {:clone_failed, err}}
    end
  end

  def restore_from_snapshot(vm_id, snapshot_name) do
    btrfs_root = Application.get_env(:mjolnir, :btrfs_root)
    source = Path.join([btrfs_root, "@snapshots", snapshot_name])
    dest = Path.join([btrfs_root, "@vms", vm_id])

    # Replace current rootfs subvolume with snapshot (VM must be stopped)
    with :ok <- File.rm_rf(dest),
         {_, 0} <- System.cmd("sudo", ["-n", "btrfs", "subvolume", "snapshot", source, dest]) do
      :ok
    end
  end
end
```

---

## 5. Networking Architecture

### 5.1 Network Topology

**Design Principle**: Masterless. No central coordinator. Nodes discover each other via DHT and form a mesh.

```
┌─────────────────────────────────────────────────────────────┐
│                    OVERLAY NETWORK                          │
│         Phase 1: Tailscale → Phase 2: Iroh DHT             │
│                                                             │
│  ┌─────────┐      ┌─────────┐      ┌─────────┐            │
│  │ Node 1  │◄────►│ Node 2  │◄────►│ Node N  │            │
│  └────┬────┘      └────┬────┘      └────┬────┘            │
│       │                │                │                  │
│       └────────────────┴────────────────┘                  │
│                  (peer-to-peer mesh)                        │
└───────┼────────────────┼────────────────┼──────────────────┘
        │                │                │
   ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
   │  TAP    │      │  TAP    │      │  TAP    │
   │ Bridge  │      │ Bridge  │      │ Bridge  │
   └────┬────┘      └────┬────┘      └────┬────┘
        │                │                │
   ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
   │tap0 tap1│      │tap0 tap1│      │tap0 tap1│
   │ │    │ │      │ │    │ │      │ │    │ │
   │VM1  VM2│      │VM3  VM4│      │VM5  VM6│
   └─────────┘      └─────────┘      └─────────┘
```

#### Discovery Evolution Path

| Phase | Mechanism | Tradeoffs |
|-------|-----------|-----------|
| **Phase 1** | Tailscale | Easy setup, handles NAT, but centralized coordination |
| **Phase 2** | Iroh DHT | Decentralized, content-addressed, integrates with our Merkle verification |
| **Phase 3** | Custom DHT | Full control, optimized for our workload patterns |

Iroh is particularly attractive bc:
- Already spec'd for verifiable streaming in `computational-fabric.md`
- DHT for node/service discovery
- Content-addressed storage for checkpoint distribution
- QUIC-based transport with hole punching

### 5.2 VM Communication Options

| Method | Latency | Use Case |
|--------|---------|----------|
| **vsock** | ~μs | Host↔VM control plane |
| **TAP + bridge** | ~100μs | VM↔VM on same host |
| **Overlay network** | ~1ms | VM↔VM across hosts |
| **π-channel (Elixir)** | ~10μs | Orchestrator↔VM messaging |

### 5.3 vsock Integration

```elixir
defmodule Mjolnir.VM.Vsock do
  @moduledoc """
  vsock provides low-latency communication between host and guest.
  We use it for the control plane and stdin/stdout streaming.
  """

  def connect(vm_id, cid \\ 3) do
    socket_path = "/tmp/mjolnir/vsock/#{vm_id}.sock"
    {:ok, socket} = :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: true])
    {:ok, socket}
  end

  def send_command(socket, command) do
    frame = :erlang.term_to_binary({:command, command})
    :gen_tcp.send(socket, <<byte_size(frame)::32, frame::binary>>)
  end

  def stream_output(socket, handler) do
    receive do
      {:tcp, ^socket, data} ->
        handler.(data)
        stream_output(socket, handler)
      {:tcp_closed, ^socket} ->
        :closed
    end
  end
end
```

---

## 6. Security Model

### 6.1 Isolation Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Cloud Hypervisor VMM (hardware virtualization)     │
│  - Minimal device model (reduced attack surface)            │
│  - seccomp-bpf + cgroups                                    │
│  - Separate kernel per VM                                   │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Network isolation                                  │
│  - Per-VM TAP devices                                       │
│  - iptables/nftables rules                                  │
│  - Optional: egress filtering                               │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Filesystem isolation                               │
│  - BTRFS subvolumes (separate namespace)                    │
│  - Read-only base images                                    │
│  - Overlay writes isolated per-VM                           │
├─────────────────────────────────────────────────────────────┤
│ Layer 4: Cryptographic identity                             │
│  - Each VM has Ed25519 keypair                             │
│  - Channels authenticated via signatures                    │
│  - Workspace encryption (optional)                          │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Secret Management

```elixir
defmodule Mjolnir.Secrets do
  @moduledoc """
  Injects secrets into VMs via vsock at boot.
  Secrets never touch the filesystem.
  """

  def inject(vm_id, secrets) when is_map(secrets) do
    {:ok, vsock} = Mjolnir.VM.Vsock.connect(vm_id)
    
    # Secrets are memory-only, injected via tmpfs inside guest
    for {name, value} <- secrets do
      Mjolnir.VM.Vsock.send_command(vsock, {:inject_secret, name, value})
    end
    
    :ok
  end
end
```

---

## 7. Integration with Mjolnir Theoretical Framework

### 7.1 Mapping to π-Calculus

| π-Calculus Concept | MicroVM Fabric Implementation |
|--------------------|-------------------------------|
| Process P | MicroVM running computation |
| Channel x | Elixir Channel.Router + vsock |
| Send x̄⟨v⟩ | Channel.send(channel_id, msg) |
| Receive x(y) | Channel.subscribe(channel_id) |
| Parallel P\|Q | Multiple VMs running concurrently |
| Restriction (νx)P | Private channel creation |
| Replication !P | VM cloning via BTRFS snapshot |

### 7.2 Mapping to Orthogonal Persistence

The orthogonal persistence pattern from `orthogonal-persistence.md` maps to our implementation:

| Concept | Implementation |
|---------|----------------|
| State persistence | BTRFS subvolume snapshots (filesystem) |
| Identity preservation | VM ID + cryptographic keypair |
| State validation | BTRFS integrity (scrub, checksums) |
| Transparent restoration | `Mjolnir.BTRFS.restore/2` |

Note: Full orthogonal persistence (memory + CPU state) is deferred. Currently we persist filesystem state only; agents/processes are expected to be resumable via their own mechanisms (conversation history, etc.).

### 7.3 Remote Closures

```elixir
defmodule Mjolnir.RemoteClosure do
  @moduledoc """
  Implements remote closures from computational-fabric.md
  using MicroVMs as the execution context.
  """

  defstruct [:id, :code, :state, :continuation, :vm_id]

  def create(code, initial_state) do
    %__MODULE__{
      id: generate_id(),
      code: code,
      state: initial_state,
      continuation: nil,
      vm_id: nil
    }
  end

  def execute(closure, input) do
    # Spawn VM if needed
    vm_id = closure.vm_id || spawn_vm_for_closure(closure)
    
    # Execute code in VM
    result = Mjolnir.VM.execute(vm_id, closure.code, [closure.state, input])
    
    # Update closure state
    %{closure | state: result.new_state, vm_id: vm_id}
  end

  def migrate(closure, target_node) do
    # Checkpoint VM
    {:ok, checkpoint} = Mjolnir.VM.checkpoint(closure.vm_id)
    
    # Transfer to target
    :ok = Mjolnir.Migration.transfer(checkpoint, target_node)
    
    # Restore on target
    {:ok, new_vm_id} = :rpc.call(target_node, Mjolnir.Checkpoint, :restore, [checkpoint])
    
    %{closure | vm_id: new_vm_id}
  end

  def synchronize(closure1, closure2) do
    # CRDT-based state merge
    merged_state = Mjolnir.CRDT.merge(closure1.state, closure2.state)
    
    %{closure1 | state: merged_state}
  end
end
```

---

## 8. Deployment & Operations

### 8.1 Host Requirements

```yaml
# Minimum host specification
cpu: 4+ cores (with VT-x/AMD-V)
memory: 16GB+ RAM
storage: 100GB+ BTRFS partition
kernel: Linux 6.1+ (6.12+ recommended, must have PVH + VIRTIO_FS)
packages:
  - cloud-hypervisor (v50+)
  - virtiofsd
  - btrfs-progs
  - erlang-otp (26+)
  - elixir (1.15+)
```

### 8.2 Installation Script

```bash
#!/bin/bash
set -euo pipefail

# Install Cloud Hypervisor
CH_VERSION="50.0"
curl -L "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v${CH_VERSION}/cloud-hypervisor-static" \
  -o /usr/local/bin/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor

# Install virtiofsd
apt-get install -y virtiofsd

# Setup BTRFS storage
mkfs.btrfs -L mjolnir /dev/sdb
mkdir -p /var/lib/mjolnir/btrfs
mount -o compress=zstd:3,noatime,ssd /dev/sdb /var/lib/mjolnir/btrfs

# Create directory structure for BTRFS subvolumes
mkdir -p /var/lib/mjolnir/btrfs/@base      # Base OS subvolumes (directories)
mkdir -p /var/lib/mjolnir/btrfs/@vms       # Per-VM rootfs clones
mkdir -p /var/lib/mjolnir/btrfs/@snapshots # Named snapshots

# PVH kernel with VIRTIO_FS built in (place your custom kernel here)
# /var/lib/mjolnir/vmlinux-ch

# Install Elixir
apt-get install -y erlang elixir

# Clone and build Mjolnir
git clone https://github.com/identikey/mjolnir /opt/mjolnir
cd /opt/mjolnir
mix deps.get
mix compile
```

### 8.3 Systemd Service

```ini
# /etc/systemd/system/mjolnir.service
[Unit]
Description=Mjolnir MicroVM Fabric
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mjolnir
Environment="MIX_ENV=prod"
Environment="MJOLNIR_NODE_NAME=mjolnir@$(hostname -f)"
ExecStart=/usr/bin/mix run --no-halt
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 8.4 Cluster Formation (Masterless)

The cluster has no master node. All nodes are peers. Discovery happens in phases:

#### Phase 1: Tailscale + Gossip

```elixir
# config/runtime.exs
import Config

# Tailscale provides the encrypted mesh; gossip finds BEAM nodes on it
config :libcluster,
  topologies: [
    mjolnir_gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_if: "tailscale0",
        multicast_addr: "230.1.1.251",
        secret: System.get_env("MJOLNIR_CLUSTER_SECRET")
      ]
    ]
  ]
```

#### Phase 2: Iroh DHT Integration

```elixir
# Future: Custom libcluster strategy using Iroh
config :libcluster,
  topologies: [
    mjolnir_iroh: [
      strategy: Mjolnir.Cluster.Strategy.Iroh,
      config: [
        # Iroh node ID derived from Ed25519 identity
        node_id: System.get_env("MJOLNIR_NODE_ID"),
        # Bootstrap nodes (optional, can discover via DHT)
        bootstrap: System.get_env("MJOLNIR_BOOTSTRAP_NODES", "") |> String.split(","),
        # Namespace for this cluster
        namespace: "mjolnir-fabric-v1"
      ]
    ]
  ]
```

```elixir
defmodule Mjolnir.Cluster.Strategy.Iroh do
  @moduledoc """
  libcluster strategy using Iroh DHT for node discovery.
  Nodes publish their BEAM node name to the DHT under a shared namespace.
  No central coordinator required.
  """
  use Cluster.Strategy
  
  def start_link(opts) do
    # Connect to local Iroh node (sidecar or embedded via Rustler)
    {:ok, iroh} = Mjolnir.Iroh.connect()
    
    # Publish our node to DHT
    :ok = Mjolnir.Iroh.publish(iroh, opts[:namespace], node())
    
    # Subscribe to namespace for new node announcements
    Mjolnir.Iroh.subscribe(iroh, opts[:namespace], fn node_name ->
      Cluster.Strategy.connect_node(node_name)
    end)
    
    {:ok, self()}
  end
end
```

#### Why Masterless Matters

1. **No SPOF**: Any node can fail without breaking discovery
2. **Edge-friendly**: Nodes behind NAT can participate equally
3. **Scalability**: DHT scales logarithmically with node count
4. **Sovereignty**: No external service dependency (post-Tailscale)

---

## 9. API Reference

### 9.1 REST API (Optional HTTP Interface)

```yaml
openapi: 3.0.0
info:
  title: Mjolnir MicroVM Fabric API
  version: 0.1.0

paths:
  /vms:
    post:
      summary: Spawn a new MicroVM
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                base_image: { type: string, default: "ubuntu-22.04" }
                vcpus: { type: integer, default: 2 }
                memory_mb: { type: integer, default: 512 }
      responses:
        201:
          description: VM created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/VM'

  /vms/{vm_id}/checkpoint:
    post:
      summary: Create a checkpoint
      responses:
        201:
          description: Checkpoint created

  /vms/{vm_id}/restore/{checkpoint_id}:
    post:
      summary: Restore from checkpoint
      responses:
        200:
          description: VM restored

  /vms/{vm_id}/migrate:
    post:
      summary: Migrate VM to another node
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                target_node: { type: string }
      responses:
        200:
          description: Migration complete

  /agents:
    post:
      summary: Spawn an AI agent
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                type: { type: string, enum: [claude_code, custom] }
                workspace: { type: string }
                init_script: { type: string }
      responses:
        201:
          description: Agent spawned
```

### 9.2 Elixir Client API

```elixir
# Spawn a VM
{:ok, vm} = Mjolnir.VM.spawn(%{
  base_image: "ubuntu-22.04",
  vcpus: 2,
  memory_mb: 1024
})

# Execute command
{:ok, output} = Mjolnir.VM.exec(vm.id, "apt update && apt install -y python3")

# Checkpoint
{:ok, checkpoint_id} = Mjolnir.VM.checkpoint(vm.id)

# Restore on another node
:ok = Mjolnir.VM.restore(checkpoint_id, target_node: :"mjolnir@node2")

# Spawn AI agent
{:ok, agent} = Mjolnir.Agent.spawn_claude_agent(%{
  workspace: "/home/user/project",
  api_key: System.get_env("ANTHROPIC_API_KEY")
})

# Send prompt
Mjolnir.Agent.send_prompt(agent, "Analyze the codebase and suggest improvements")

# Checkpoint agent mid-task
{:ok, _} = Mjolnir.Agent.checkpoint(agent)
```

---

## 10. Iroh Integration

Iroh (from n0.computer) provides content-addressed storage with DHT—already spec'd in `computational-fabric.md` for verifiable streaming. Here we extend it to:
- **Node discovery** (DHT-based, masterless)
- **Checkpoint distribution** (content-addressed, deduped)
- **Service registry** (ρ-calculus pattern matching over DHT)

### 10.1 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     IROH LAYER                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │ Node        │  │ Content     │  │ Service     │        │
│  │ Discovery   │  │ Distribution│  │ Registry    │        │
│  │ (DHT)       │  │ (blobs)     │  │ (DHT+ρ)     │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
│         │                │                │                │
│         └────────────────┴────────────────┘                │
│                          │                                  │
│                    ┌─────┴─────┐                           │
│                    │ Iroh Node │ (Rust, via Rustler NIF)   │
│                    └───────────┘                           │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   ELIXIR/OTP LAYER                          │
│  Mjolnir.Iroh GenServer wraps Iroh node                    │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Checkpoint Distribution via Iroh

Instead of SSH + btrfs send/receive, use Iroh for checkpoint transfer:

```elixir
defmodule Mjolnir.Checkpoint.IrohStore do
  @moduledoc """
  Store and retrieve checkpoints via Iroh's content-addressed storage.
  Checkpoints are immutable blobs identified by BLAKE3 hash.
  """

  def store_checkpoint(checkpoint_id, paths) do
    # Create a collection (directory-like structure)
    {:ok, collection} = Mjolnir.Iroh.create_collection([
      {"memory", paths.memory_snapshot},
      {"fs.btrfs", paths.fs_snapshot_archive},
      {"metadata.json", paths.metadata}
    ])
    
    # Get the root hash (content address)
    hash = Mjolnir.Iroh.hash(collection)
    
    # Publish to DHT so other nodes can find it
    :ok = Mjolnir.Iroh.publish("checkpoints/#{checkpoint_id}", hash)
    
    {:ok, hash}
  end

  def fetch_checkpoint(checkpoint_id, target_path) do
    # Lookup in DHT
    {:ok, hash} = Mjolnir.Iroh.resolve("checkpoints/#{checkpoint_id}")
    
    # Fetch from network (automatically finds peers with content)
    {:ok, _} = Mjolnir.Iroh.download(hash, target_path)
    
    :ok
  end
end
```

### 10.3 Service Registry via Iroh DHT

Implements ρ-calculus service discovery over DHT:

```elixir
defmodule Mjolnir.ServiceRegistry.Iroh do
  @moduledoc """
  Decentralized service registry using Iroh DHT.
  Services publish capabilities; consumers query by pattern.
  """

  def register_service(service_id, capabilities) do
    # Create signed service descriptor
    descriptor = %{
      id: service_id,
      node: node(),
      capabilities: capabilities,
      public_key: Mjolnir.Identity.public_key(),
      timestamp: DateTime.utc_now()
    }
    
    signed = Mjolnir.Identity.sign(descriptor)
    
    # Publish to DHT under capability-based keys
    for cap <- capabilities do
      Mjolnir.Iroh.publish("services/capability/#{cap}", signed)
    end
    
    # Also publish under service ID
    Mjolnir.Iroh.publish("services/id/#{service_id}", signed)
  end

  def discover(capability_pattern) do
    # Query DHT for matching capabilities
    {:ok, entries} = Mjolnir.Iroh.get_all("services/capability/#{capability_pattern}")
    
    entries
    |> Enum.map(&verify_and_decode/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
  end
end
```

### 10.4 Iroh Integration via Rustler

```elixir
defmodule Mjolnir.Iroh.Native do
  use Rustler, otp_app: :mjolnir, crate: "mjolnir_iroh"

  # NIFs implemented in Rust
  def start_node(_config), do: :erlang.nif_error(:nif_not_loaded)
  def publish(_node, _key, _value), do: :erlang.nif_error(:nif_not_loaded)
  def resolve(_node, _key), do: :erlang.nif_error(:nif_not_loaded)
  def download(_node, _hash, _path), do: :erlang.nif_error(:nif_not_loaded)
  def create_collection(_node, _files), do: :erlang.nif_error(:nif_not_loaded)
end
```

```rust
// native/mjolnir_iroh/src/lib.rs
use iroh::{client::Client, node::Node};
use rustler::{Encoder, Env, NifResult, Term};

#[rustler::nif]
fn start_node(config: NodeConfig) -> NifResult<NodeHandle> {
    let rt = tokio::runtime::Runtime::new()?;
    let node = rt.block_on(async {
        Node::memory().spawn().await
    })?;
    Ok(NodeHandle::new(node, rt))
}

#[rustler::nif]
fn publish(node: NodeHandle, key: String, value: Binary) -> NifResult<Atom> {
    node.rt.block_on(async {
        let client = node.node.client();
        // Publish to DHT...
    })?;
    Ok(atoms::ok())
}
```

---

## 11. Future Directions

### 11.1 GPU Passthrough

For AI workloads requiring GPU:
- VFIO passthrough for dedicated GPU
- virtio-gpu for shared GPU (experimental)
- Integration with NVIDIA MIG for partitioning

### 11.2 WebAssembly Guests

Lighter-weight alternative for trusted code:
- Wasmtime as guest runtime
- WASI for system access
- Sub-millisecond startup

### 11.3 Distributed Snapshots

Coordinated checkpointing across multiple VMs:
- Chandy-Lamport algorithm for consistent cuts
- Vector clock synchronization
- Atomic multi-VM checkpoint/restore

### 11.4 Economic Layer (Capability Marketplace)

Integrates with the capability marketplace from `computational-fabric.md`:

```elixir
defmodule Mjolnir.Marketplace do
  @moduledoc """
  Economic layer for computational fabric.
  Nodes offer compute resources; consumers pay per usage.
  Built on the cryptographic identity system from computational-fabric.md.
  """

  defstruct [:node_id, :offerings, :pricing, :reputation]

  def register_offering(offering) do
    # Publish to DHT with signed pricing
    descriptor = %{
      node: node(),
      resources: offering.resources,  # {:vcpus, 4}, {:memory_gb, 8}, etc.
      pricing: offering.pricing,       # per-hour rates
      capabilities: offering.capabilities,
      public_key: Mjolnir.Identity.public_key()
    }
    
    Mjolnir.ServiceRegistry.Iroh.register_service(
      "compute/#{node()}",
      [:compute | offering.capabilities]
    )
  end

  def request_compute(requirements, budget) do
    # Find nodes matching requirements
    providers = Mjolnir.ServiceRegistry.Iroh.discover("compute")
    
    # Filter by budget and requirements
    suitable = providers
    |> Enum.filter(&meets_requirements?(&1, requirements))
    |> Enum.filter(&within_budget?(&1, budget))
    |> Enum.sort_by(&reputation_score/1, :desc)
    
    # Return best match
    List.first(suitable)
  end
end
```

**Payment channels** (future): Integrate with Lightning Network or similar for micropayments per compute-second.


---

## Appendix A: BTRFS Best Practices

Since we use BTRFS subvolume directories (not ext4 file images), cloning and snapshotting use `btrfs subvolume snapshot` for instant CoW subvolume creation:

```bash
# Enable quotas for overall storage limits (optional)
btrfs quota enable /var/lib/mjolnir/btrfs

# Balance to prevent fragmentation (run periodically)
btrfs balance start -dusage=50 /var/lib/mjolnir/btrfs

# Scrub for data integrity (weekly cron)
btrfs scrub start /var/lib/mjolnir/btrfs

# Check reflink sharing (how much space is shared via CoW)
compsize /var/lib/mjolnir/btrfs/@vms/

# Defragment directory (may break reflinks - use with caution)
# btrfs filesystem defragment -r /var/lib/mjolnir/btrfs/@vms/{vm_id}
```

### Subvolume Snapshot Behavior Notes

When using `btrfs subvolume snapshot`:
- **Initial snapshot**: ~1ms metadata operation, 0 bytes used (shares all blocks with source via CoW)
- **After writes**: Only changed blocks use new space (copy-on-write)
- **Defragmentation**: Can break CoW block sharing, causing space increase

To check actual disk usage accounting for shared blocks:
```bash
# Install compsize if needed: apt install btrfs-compsize
compsize /var/lib/mjolnir/btrfs/@vms/
```

## Appendix B: Firecracker Jailer (Legacy — Deprecated)

> **Note**: Firecracker is no longer the active hypervisor. Cloud Hypervisor v50 is the default. This section is retained for historical reference only.

The Firecracker jailer provided additional isolation via a chroot sandbox:

```bash
jailer --id ${VM_ID} \
  --exec-file /usr/local/bin/firecracker \
  --uid 1000 --gid 1000 \
  --chroot-base-dir /var/lib/mjolnir/jails \
  --netns /var/run/netns/mjolnir-${VM_ID} \
  -- --config-file /config.json
```

Cloud Hypervisor achieves similar isolation via seccomp-bpf and cgroups without requiring a separate jailer binary.

## Appendix C: Kernel Configuration

Minimal kernel config for microVMs:

```
# Required for Cloud Hypervisor (PVH boot)
CONFIG_PVH=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_NET=y
CONFIG_VSOCK=y
CONFIG_VIRTIO_VSOCK=y

# Required for virtio-fs (host filesystem sharing)
CONFIG_VIRTIO_FS=y
CONFIG_FUSE_FS=y

# Filesystem (guest side; ext4 optional for legacy)
CONFIG_EXT4_FS=y

# Networking
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y

# Disable unnecessary features
# CONFIG_MODULES is not set
# CONFIG_USB is not set
# CONFIG_SOUND is not set
```

---

## References

1. Cloud Hypervisor Documentation: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/
2. Cloud Hypervisor API Reference: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/vmm/src/api/openapi/cloud-hypervisor.yaml
3. virtio-fs / virtiofsd: https://virtio-fs.gitlab.io/
4. BTRFS Documentation: https://btrfs.readthedocs.io/
5. Elixir/OTP Documentation: https://hexdocs.pm/elixir/
6. libcluster: https://github.com/bitwalker/libcluster
7. vsock: https://man7.org/linux/man-pages/man7/vsock.7.html
8. Firecracker Design (legacy reference): https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md
