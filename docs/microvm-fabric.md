# Mjolnir MicroVM Execution Fabric
## Distributed Checkpointable Linux Shell Spawning System

### Executive Summary

This document specifies a distributed computational fabric where:
- **Compute units** are Firecracker microVMs (Linux shells with full `apt` access)
- **State persistence** leverages BTRFS copy-on-write snapshots for instant checkpointing
- **Orchestration** is handled by Elixir/OTP for actor-based concurrency, supervision trees, and distributed message-passing
- **AI agents** (e.g., Claude Code) run natively inside microVMs with full system access

The fabric implements orthogonal persistence at the VM level—processes can be paused, checkpointed, migrated, and resumed transparently across nodes.

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
│  │Firecracker│  │ │  │Firecracker│  │ │  │Firecracker│  │
│  │  Manager  │  │ │  │  Manager  │  │ │  │  Manager  │  │
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

### 2.1 Firecracker MicroVM Layer

Firecracker provides:
- **~125ms boot time** (vs minutes for traditional VMs)
- **~5MB memory overhead** per microVM
- **Minimal attack surface** (reduced device model)
- **Snapshotting** of memory + device state

#### MicroVM Configuration

```json
{
  "boot-source": {
    "kernel_image_path": "/var/lib/mjolnir/vmlinux-5.10",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/var/lib/mjolnir/btrfs/vms/{vm_id}/overlay.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 512,
    "smt": false
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "{generated_mac}",
      "host_dev_name": "tap{vm_id}"
    }
  ],
  "vsock": {
    "guest_cid": 3,
    "uds_path": "/tmp/mjolnir/vsock/{vm_id}.sock"
  }
}
```

#### Kernel Selection

| Kernel Version | Use Case | Notes |
|----------------|----------|-------|
| 5.10 LTS | Production workloads | Stable, well-tested with FC |
| 6.1 LTS | Newer BTRFS features | Better compression, zoned storage |
| 6.6 LTS | Bleeding edge | Latest perf improvements |

**Recommendation**: 6.1 LTS—best BTRFS features without bleeding-edge risk.

#### Base Image Selection

| Distro | Size | Pros | Cons |
|--------|------|------|------|
| **Debian 12** | ~300MB | Minimal, stable, apt-native, no cruft | Slightly older packages |
| Ubuntu 22.04 | ~500MB | Better docs, more tested | Snap pollution, larger |
| Alpine 3.19 | ~50MB | Tiny, fast boot | musl libc breaks some software |

**Decision**: **Debian 12 (Bookworm)** as default base. Minimal, stable, same apt as Ubuntu but leaner. Alpine available for specialized lightweight workloads where musl compatibility is verified.

### 2.2 BTRFS Storage Layer

BTRFS provides the checkpointing foundation via copy-on-write semantics:

```
/var/lib/mjolnir/btrfs/
├── @base/                    # Base OS images (immutable)
│   ├── ubuntu-22.04/
│   ├── debian-12/
│   └── alpine-3.19/
├── @vms/                     # Per-VM overlays
│   ├── {vm_id}/
│   │   ├── overlay/          # CoW layer on base
│   │   ├── workspace/        # Agent workspace
│   │   └── .snapshots/       # Checkpoint history
│   │       ├── checkpoint-001/
│   │       ├── checkpoint-002/
│   │       └── latest -> checkpoint-002/
└── @snapshots/               # Archived/transferred snapshots
    └── {vm_id}/
        └── {timestamp}/
```

#### BTRFS Operations

```bash
# Create base subvolume from rootfs
btrfs subvolume create /var/lib/mjolnir/btrfs/@base/ubuntu-22.04

# Clone for new VM (instant, CoW)
btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@base/ubuntu-22.04 \
  /var/lib/mjolnir/btrfs/@vms/{vm_id}/overlay

# Checkpoint (instant snapshot)
btrfs subvolume snapshot -r /var/lib/mjolnir/btrfs/@vms/{vm_id}/overlay \
  /var/lib/mjolnir/btrfs/@vms/{vm_id}/.snapshots/checkpoint-{n}

# Send to remote node (incremental)
btrfs send -p /prev/snapshot /new/snapshot | ssh node2 btrfs receive /dest/

# Restore from checkpoint
btrfs subvolume delete /var/lib/mjolnir/btrfs/@vms/{vm_id}/overlay
btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@vms/{vm_id}/.snapshots/checkpoint-{n} \
  /var/lib/mjolnir/btrfs/@vms/{vm_id}/overlay
```

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
    :firecracker_pid,
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
    with {:ok, btrfs_subvol} <- setup_btrfs_overlay(state.config),
         {:ok, fc_config} <- generate_firecracker_config(state.config, btrfs_subvol),
         {:ok, fc_pid} <- start_firecracker(fc_config),
         {:ok, vsock} <- connect_vsock(state.id) do
      
      new_state = %{state | 
        firecracker_pid: fc_pid,
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
  
  defp setup_btrfs_overlay(config) do
    base_image = config.base_image || "ubuntu-22.04"
    subvol_path = "/var/lib/mjolnir/btrfs/@vms/#{config.id}/overlay"
    
    case System.cmd("btrfs", [
      "subvolume", "snapshot",
      "/var/lib/mjolnir/btrfs/@base/#{base_image}",
      subvol_path
    ]) do
      {_, 0} -> {:ok, subvol_path}
      {err, _} -> {:error, {:btrfs_snapshot_failed, err}}
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

### 3.1 Checkpoint Types

| Type | Scope | Use Case |
|------|-------|----------|
| **Memory Snapshot** | Firecracker VM state | Pause/resume, fast restore |
| **Filesystem Snapshot** | BTRFS subvolume | Workspace preservation |
| **Full Checkpoint** | Both + metadata | Migration, long-term archival |
| **Incremental Checkpoint** | Delta from previous | Periodic checkpointing |

### 3.2 Checkpoint Coordinator

```elixir
defmodule Mjolnir.Checkpoint.Coordinator do
  use GenServer
  
  defstruct [
    :checkpoint_store,    # Where checkpoints are persisted
    :retention_policy,    # How long to keep checkpoints
    :scheduled_jobs       # Periodic checkpoint schedules
  ]

  def schedule_periodic(vm_id, interval_ms) do
    GenServer.call(__MODULE__, {:schedule, vm_id, interval_ms})
  end

  def create_checkpoint(vm_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create, vm_id, opts}, :infinity)
  end

  def restore_checkpoint(vm_id, checkpoint_id, opts \\ []) do
    GenServer.call(__MODULE__, {:restore, vm_id, checkpoint_id, opts}, :infinity)
  end

  def list_checkpoints(vm_id) do
    GenServer.call(__MODULE__, {:list, vm_id})
  end

  @impl true
  def handle_call({:create, vm_id, opts}, _from, state) do
    checkpoint_id = generate_checkpoint_id()
    
    with :ok <- pause_vm(vm_id),
         {:ok, mem_path} <- snapshot_firecracker_memory(vm_id, checkpoint_id),
         {:ok, fs_path} <- snapshot_btrfs(vm_id, checkpoint_id),
         {:ok, metadata} <- capture_metadata(vm_id),
         :ok <- store_checkpoint(checkpoint_id, %{
           vm_id: vm_id,
           memory: mem_path,
           filesystem: fs_path,
           metadata: metadata,
           created_at: DateTime.utc_now()
         }),
         :ok <- maybe_resume(vm_id, opts) do
      
      {:reply, {:ok, checkpoint_id}, state}
    else
      error ->
        resume_vm(vm_id)  # Ensure VM isn't left paused
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:restore, vm_id, checkpoint_id, opts}, _from, state) do
    with {:ok, checkpoint} <- fetch_checkpoint(checkpoint_id),
         :ok <- stop_existing_vm(vm_id),
         :ok <- restore_btrfs_snapshot(vm_id, checkpoint.filesystem),
         {:ok, _pid} <- start_vm_from_snapshot(vm_id, checkpoint) do
      
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  defp snapshot_firecracker_memory(vm_id, checkpoint_id) do
    snapshot_path = "/var/lib/mjolnir/checkpoints/#{vm_id}/#{checkpoint_id}"
    File.mkdir_p!(snapshot_path)
    
    # Firecracker snapshot API
    body = Jason.encode!(%{
      snapshot_type: "Full",
      snapshot_path: "#{snapshot_path}/snapshot",
      mem_file_path: "#{snapshot_path}/memory"
    })
    
    case http_put("http+unix:///tmp/mjolnir/fc/#{vm_id}.sock/snapshot/create", body) do
      {:ok, 204} -> {:ok, snapshot_path}
      error -> {:error, {:snapshot_failed, error}}
    end
  end

  defp snapshot_btrfs(vm_id, checkpoint_id) do
    source = "/var/lib/mjolnir/btrfs/@vms/#{vm_id}/overlay"
    dest = "/var/lib/mjolnir/btrfs/@vms/#{vm_id}/.snapshots/#{checkpoint_id}"
    
    case System.cmd("btrfs", ["subvolume", "snapshot", "-r", source, dest]) do
      {_, 0} -> {:ok, dest}
      {err, _} -> {:error, {:btrfs_failed, err}}
    end
  end
end
```

### 3.3 Cross-Node Migration

```elixir
defmodule Mjolnir.Migration do
  @moduledoc """
  Handles live migration of VMs between nodes using BTRFS send/receive
  and Firecracker snapshot restore.
  """

  def migrate(vm_id, source_node, target_node, opts \\ []) do
    with {:ok, checkpoint_id} <- create_migration_checkpoint(source_node, vm_id),
         :ok <- transfer_checkpoint(checkpoint_id, source_node, target_node),
         :ok <- restore_on_target(target_node, vm_id, checkpoint_id),
         :ok <- cleanup_source(source_node, vm_id, opts) do
      :ok
    end
  end

  defp transfer_checkpoint(checkpoint_id, source, target) do
    # Use BTRFS send/receive for efficient incremental transfer
    source_path = "/var/lib/mjolnir/btrfs/@vms/*/#{checkpoint_id}"
    
    # Get parent snapshot for incremental send
    parent = get_parent_snapshot(source, checkpoint_id)
    
    send_cmd = case parent do
      nil -> "btrfs send #{source_path}"
      p -> "btrfs send -p #{p} #{source_path}"
    end
    
    # Stream via SSH or internal transport
    :rpc.call(source, System, :cmd, ["sh", ["-c", 
      "#{send_cmd} | ssh #{target} 'btrfs receive /var/lib/mjolnir/btrfs/@incoming/'"
    ]])
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

```elixir
defmodule Mjolnir.Agent.Workspace do
  @moduledoc """
  Manages agent workspaces using BTRFS subvolumes.
  Workspaces can be cloned, snapshotted, and shared.
  """

  def create(agent_id, opts \\ []) do
    base = opts[:clone_from] || "/var/lib/mjolnir/btrfs/@workspaces/empty"
    path = "/var/lib/mjolnir/btrfs/@workspaces/#{agent_id}"
    
    System.cmd("btrfs", ["subvolume", "snapshot", base, path])
    {:ok, path}
  end

  def snapshot(agent_id, name) do
    source = "/var/lib/mjolnir/btrfs/@workspaces/#{agent_id}"
    dest = "#{source}/.snapshots/#{name}"
    
    System.cmd("btrfs", ["subvolume", "snapshot", "-r", source, dest])
    {:ok, dest}
  end

  def clone(source_agent_id, target_agent_id) do
    source = "/var/lib/mjolnir/btrfs/@workspaces/#{source_agent_id}"
    target = "/var/lib/mjolnir/btrfs/@workspaces/#{target_agent_id}"
    
    # Instant CoW clone
    System.cmd("btrfs", ["subvolume", "snapshot", source, target])
    {:ok, target}
  end

  def diff(snapshot1, snapshot2) do
    # Get changed files between snapshots
    {output, 0} = System.cmd("btrfs", ["send", "--no-data", "-p", snapshot1, snapshot2])
    parse_btrfs_diff(output)
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
│ Layer 1: Firecracker VMM (hardware virtualization)         │
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

The orthogonal persistence pattern from `orthogonal-persistence.md` maps directly:

| Concept | Implementation |
|---------|----------------|
| State persistence | BTRFS snapshot + Firecracker memory dump |
| Identity preservation | VM ID + cryptographic keypair |
| State validation | Checkpoint integrity verification |
| Transparent restoration | `Mjolnir.Checkpoint.restore/2` |

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
kernel: Linux 5.10+ (6.1+ recommended)
packages:
  - firecracker (1.5+)
  - btrfs-progs
  - erlang-otp (26+)
  - elixir (1.15+)
```

### 8.2 Installation Script

```bash
#!/bin/bash
set -euo pipefail

# Install Firecracker
FC_VERSION="1.5.0"
curl -L "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz" | tar xz
mv release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64 /usr/local/bin/firecracker
mv release-v${FC_VERSION}-x86_64/jailer-v${FC_VERSION}-x86_64 /usr/local/bin/jailer

# Setup BTRFS storage
mkfs.btrfs -L mjolnir /dev/sdb
mkdir -p /var/lib/mjolnir/btrfs
mount -o compress=zstd:3,noatime,ssd /dev/sdb /var/lib/mjolnir/btrfs

# Create BTRFS structure
btrfs subvolume create /var/lib/mjolnir/btrfs/@base
btrfs subvolume create /var/lib/mjolnir/btrfs/@vms
btrfs subvolume create /var/lib/mjolnir/btrfs/@snapshots
btrfs subvolume create /var/lib/mjolnir/btrfs/@workspaces

# Download base kernel
curl -L "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin" \
  -o /var/lib/mjolnir/vmlinux-5.10

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

```bash
# Enable quotas for per-VM storage limits
btrfs quota enable /var/lib/mjolnir/btrfs

# Set quota for VM subvolume
btrfs qgroup limit 10G /var/lib/mjolnir/btrfs/@vms/{vm_id}

# Balance to prevent fragmentation (run periodically)
btrfs balance start -dusage=50 /var/lib/mjolnir/btrfs

# Scrub for data integrity (weekly cron)
btrfs scrub start /var/lib/mjolnir/btrfs

# Defragment specific subvolume
btrfs filesystem defragment -r /var/lib/mjolnir/btrfs/@vms/{vm_id}
```

## Appendix B: Firecracker Jailer

For production deployments, use jailer for additional isolation:

```bash
jailer --id ${VM_ID} \
  --exec-file /usr/local/bin/firecracker \
  --uid 1000 --gid 1000 \
  --chroot-base-dir /var/lib/mjolnir/jails \
  --netns /var/run/netns/mjolnir-${VM_ID} \
  -- --config-file /config.json
```

## Appendix C: Kernel Configuration

Minimal kernel config for microVMs:

```
# Required for Firecracker
CONFIG_VIRTIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VSOCK=y
CONFIG_VIRTIO_VSOCK=y

# Filesystem
CONFIG_EXT4_FS=y
CONFIG_BTRFS_FS=y

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

1. Firecracker Design: https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md
2. Firecracker Snapshotting: https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md
3. BTRFS Documentation: https://btrfs.readthedocs.io/
4. Elixir/OTP Documentation: https://hexdocs.pm/elixir/
5. libcluster: https://github.com/bitwalker/libcluster
6. vsock: https://man7.org/linux/man-pages/man7/vsock.7.html
