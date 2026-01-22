# Mjolnir Project Roadmap
## From Theory to Distributed Computation Fabric

### Vision

Mjolnir is a distributed computational fabric where:
- **Any Linux shell** can be spawned on-demand as an isolated microVM
- **State is orthogonally persistent**—checkpoint, migrate, resume anywhere
- **AI agents** run with full system access, safely sandboxed
- **Channels** (π-calculus style) connect processes across the network
- **Economic incentives** enable a decentralized compute marketplace

---

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 5: Applications                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │ AI Agents   │  │ Dev Envs    │  │ Batch Jobs  │                 │
│  │ (Claude)    │  │ (ephemeral) │  │ (workflows) │                 │
│  └─────────────┘  └─────────────┘  └─────────────┘                 │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 4: Agent & Workflow Orchestration    [computational-fabric]  │
│  - Multi-agent choreography                                         │
│  - Cross-org trust & authentication                                 │
│  - Capability marketplace                                           │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 3: Type Sync & Messaging             [spec.md]               │
│  - Universal Type Descriptors                                       │
│  - Transport abstraction (HTTP, WS, WebRTC)                        │
│  - Channel routing (fan-out, pub-sub, round-robin)                 │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 2: MicroVM Execution Fabric          [microvm-fabric.md]     │
│  - Firecracker VM management                                        │
│  - BTRFS checkpointing                                              │
│  - Elixir/OTP orchestration                                         │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 1: Theoretical Foundations           [everything-is-a-channel]│
│  - π-calculus (remote closures)             [orthogonal-persistence]│
│  - ρ-calculus (service discovery)           [event-queue]           │
│  - Cryptographic identity                                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Foundational Infrastructure (Weeks 1-4)

### Milestone 1.1: Single-Node VM Spawning
**Goal**: Spawn Firecracker VMs programmatically from Elixir

- [ ] Setup Elixir project with OTP supervision tree
- [ ] Implement `Mjolnir.Firecracker.spawn/1` to launch VMs via API
- [ ] Create base Ubuntu 22.04 rootfs image
- [ ] Implement vsock communication for host↔guest control
- [ ] Basic VM lifecycle: start, stop, status

**Deliverables**:
```elixir
{:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-22.04", memory_mb: 512})
{:ok, "hello"} = Mjolnir.VM.exec(vm.id, "echo hello")
:ok = Mjolnir.VM.stop(vm.id)
```

### Milestone 1.2: BTRFS Integration
**Goal**: Instant CoW clones and snapshots for VM filesystems

Firecracker requires ext4 file images, so we store ext4 images on BTRFS and use reflink (`cp --reflink=auto`) for instant copy-on-write cloning.

- [x] Mount BTRFS partition with optimal settings
- [x] Create directory structure (@base, @vms, @snapshots)
- [x] Implement `Mjolnir.BTRFS.clone/2` using reflink copy
- [ ] Implement `Mjolnir.BTRFS.snapshot/2` for checkpointing
- [ ] Quota management per-VM

**Architecture Note**: We use ext4 images on BTRFS (not BTRFS subvolumes) because Firecracker needs block device images. BTRFS reflinks give us instant CoW cloning of these ext4 files.

**Deliverables**:
```elixir
# Clone base ext4 image for new VM (instant via reflink)
{:ok, path} = Mjolnir.BTRFS.clone("debian-12", "vm-123")
# => {:ok, "/var/lib/mjolnir/btrfs/@vms/vm-123/rootfs.ext4"}

# Snapshot VM rootfs (for checkpointing)
{:ok, snap} = Mjolnir.BTRFS.snapshot("vm-123", "checkpoint-1")
# => {:ok, "/var/lib/mjolnir/btrfs/@snapshots/vm-123/checkpoint-1.ext4"}
```

### Milestone 1.3: Checkpointing System
**Goal**: Full VM checkpoint (memory + disk) and restore

- [ ] Implement Firecracker snapshot API integration
- [ ] Coordinate memory + BTRFS snapshots atomically
- [ ] Implement `Mjolnir.Checkpoint.create/1` and `restore/1`
- [ ] Checkpoint metadata storage and retrieval

**Deliverables**:
```elixir
{:ok, checkpoint_id} = Mjolnir.Checkpoint.create(vm_id)
{:ok, new_vm_id} = Mjolnir.Checkpoint.restore(checkpoint_id)
```

---

## Phase 2: Distribution (Weeks 5-8)

### Milestone 2.1: Multi-Node Cluster
**Goal**: Elixir cluster spanning multiple hosts

- [ ] Configure libcluster for node discovery
- [ ] Implement distributed VM registry
- [ ] Node health monitoring and capacity tracking
- [ ] Scheduler for VM placement decisions

**Deliverables**:
```elixir
Mjolnir.Cluster.nodes()
# => [:"mjolnir@host1", :"mjolnir@host2", :"mjolnir@host3"]

Mjolnir.Scheduler.place(%{vcpus: 4, memory_mb: 4096})
# => {:ok, :"mjolnir@host2"}
```

### Milestone 2.2: Cross-Node Migration
**Goal**: Live-migrate VMs between hosts

- [ ] Implement BTRFS send/receive for filesystem transfer
- [ ] Implement checkpoint transfer protocol
- [ ] Coordinate checkpoint → transfer → restore workflow
- [ ] Handle network reconfiguration post-migration

**Deliverables**:
```elixir
:ok = Mjolnir.VM.migrate(vm_id, target_node: :"mjolnir@host2")
```

### Milestone 2.3: Channel System
**Goal**: π-calculus-inspired message channels across fabric

- [ ] Implement `Mjolnir.Channel` GenServer
- [ ] Local and distributed channel routing
- [ ] Channel subscription and message delivery
- [ ] Channel passing (sending channels over channels)

**Deliverables**:
```elixir
{:ok, ch} = Mjolnir.Channel.create("my-channel")
:ok = Mjolnir.Channel.subscribe(ch, self())
:ok = Mjolnir.Channel.send(ch, {:message, "hello"})
# Receive: {:channel_message, ch, {:message, "hello"}}
```

---

## Phase 3: AI Agent Integration (Weeks 9-12)

### Milestone 3.1: Agent Execution Environment
**Goal**: Spawn AI agents (Claude Code) in microVMs

- [ ] Create AI-optimized base image (ubuntu-22.04-ai)
- [ ] Implement agent spawn with workspace provisioning
- [ ] Secret injection via vsock (API keys, tokens)
- [ ] Agent stdin/stdout channel bridging

**Deliverables**:
```elixir
{:ok, agent} = Mjolnir.Agent.spawn(:claude_code, %{
  workspace: "/projects/myrepo",
  secrets: %{anthropic_api_key: "..."}
})

Mjolnir.Agent.prompt(agent, "Analyze this codebase")
```

### Milestone 3.2: Agent State Management
**Goal**: Checkpoint and restore agent sessions

- [ ] Agent checkpoint including conversation state
- [ ] Workspace snapshots for agent projects
- [ ] Agent cloning (fork agent with same context)
- [ ] Long-running agent support (periodic checkpoints)

**Deliverables**:
```elixir
{:ok, cp} = Mjolnir.Agent.checkpoint(agent)
{:ok, cloned_agent} = Mjolnir.Agent.clone(agent)
```

### Milestone 3.3: Multi-Agent Workflows
**Goal**: Choreographed multi-agent task execution

- [ ] Workflow definition DSL
- [ ] Agent-to-agent channel communication
- [ ] Workflow checkpointing (all agents atomically)
- [ ] Result aggregation and validation

**Deliverables**:
```elixir
workflow = Mjolnir.Workflow.define do
  step :analyze, agent: :claude, prompt: "Analyze the architecture"
  step :implement, agent: :claude, depends_on: :analyze
  step :review, agent: :claude, depends_on: :implement
end

{:ok, result} = Mjolnir.Workflow.execute(workflow)
```

---

## Phase 3.5: Iroh Integration (Weeks 10-12, parallel with Phase 3)

### Milestone 3.5.1: Iroh Node Sidecar
**Goal**: Run Iroh node alongside Elixir, integrate via Rustler NIF

- [ ] Setup Rustler project for Iroh bindings
- [ ] Implement basic NIFs: `start_node`, `publish`, `resolve`
- [ ] GenServer wrapper for Iroh node lifecycle
- [ ] Test DHT publish/resolve

### Milestone 3.5.2: Masterless Discovery
**Goal**: Replace Tailscale dependency with Iroh DHT

- [ ] Implement `Mjolnir.Cluster.Strategy.Iroh` for libcluster
- [ ] Node announcement/discovery via DHT
- [ ] Graceful fallback to Tailscale if Iroh unreachable
- [ ] Test cluster formation without central coordinator

### Milestone 3.5.3: Checkpoint Distribution
**Goal**: Distribute checkpoints via Iroh instead of SSH

- [ ] Store checkpoints as Iroh collections (content-addressed)
- [ ] Implement `Mjolnir.Checkpoint.IrohStore`
- [ ] Automatic deduplication of shared base images
- [ ] Verify checkpoint integrity via BLAKE3 on retrieval

---

## Phase 4: Production Hardening (Weeks 13-16)

### Milestone 4.1: Security
- [ ] Jailer integration for Firecracker
- [ ] Network isolation (per-VM netns)
- [ ] Cryptographic identity per VM (Ed25519)
- [ ] Encrypted checkpoint storage
- [ ] Audit logging

### Milestone 4.2: Observability
- [ ] Prometheus metrics export
- [ ] Distributed tracing (OpenTelemetry)
- [ ] Log aggregation
- [ ] Alerting on node/VM failures

### Milestone 4.3: Reliability
- [ ] Automatic VM restart on failure
- [ ] Node failure recovery (migrate VMs)
- [ ] Checkpoint retention policies
- [ ] BTRFS scrub/balance automation

---

## Phase 5: Ecosystem (Weeks 17+)

### Milestone 5.1: CLI & Developer Experience
- [ ] `mjolnir` CLI tool
- [ ] `mjolnir vm spawn`, `mjolnir vm exec`, etc.
- [ ] `mjolnir agent spawn --type claude`
- [ ] Interactive shell into VMs

### Milestone 5.2: Web Dashboard
- [ ] Real-time cluster visualization
- [ ] VM management UI
- [ ] Agent interaction interface
- [ ] Checkpoint browser

### Milestone 5.3: Economic Layer
- [ ] Resource accounting (CPU-hours, memory)
- [ ] Capability marketplace integration
- [ ] Node operator incentives
- [ ] Usage-based billing

### Milestone 5.4: Advanced Features
- [ ] GPU passthrough for AI workloads
- [ ] Distributed snapshots (Chandy-Lamport)
- [ ] WebAssembly guest support
- [ ] Edge node deployment

---

## Document Index

| Document | Layer | Description | Status |
|----------|-------|-------------|--------|
| [computational-fabric.md](computational-fabric.md) | Theory | π/ρ-calculus, crypto identity, MCP integration, economic layer | Draft |
| [spec.md](spec.md) | Messaging | Type synchronization, transport abstraction, routing patterns | Draft |
| [microvm-fabric.md](microvm-fabric.md) | Execution | Firecracker + BTRFS + Elixir + Iroh implementation | Draft |
| [orthogonal-persistence.md](orthogonal-persistence.md) | Pattern | Checkpoint/restore semantics, process calculus mapping | Draft |
| [everything-is-a-channel.md](everything-is-a-channel.md) | Philosophy | Channels as universal primitive | Notes |
| [event-queue.md](event-queue.md) | Notes | Email as robust event queue, TCP/UART streams | Notes |
| [roadmap.md](roadmap.md) | Meta | This document; phases, decisions, index | Active |

---

## Tech Stack Summary

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **Virtualization** | Firecracker | Sub-second boot, minimal overhead, snapshotting |
| **Guest OS** | **Debian 12 (Bookworm)** | Minimal, apt-native, no Ubuntu bloat |
| **Filesystem** | BTRFS | CoW snapshots, send/receive, compression |
| **Orchestration** | Elixir/OTP | Supervision trees, distributed by default, message-passing |
| **Host OS** | Debian 12 or Ubuntu 22.04 | Stable, good Firecracker support |
| **Kernel** | Linux 6.1 LTS | Modern BTRFS, good virtualization support |
| **Networking (Phase 1)** | Tailscale | Encrypted overlay, easy NAT traversal |
| **Networking (Phase 2)** | Iroh DHT | Masterless discovery, content-addressed checkpoints |
| **Content Distribution** | Iroh | DHT + BLAKE3 verification (already in computational-fabric.md) |
| **Workload** | Shell + apt | Run any Linux program; AI agents are just one use case |

### Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Base distro | Debian 12 | Same apt as Ubuntu, ~200MB leaner, no Snap/cruft |
| Master node | **None** | Peer-to-peer mesh; any node can fail without breaking cluster |
| Discovery Phase 1 | Tailscale | Easy WAN mesh, handles NAT; temporary centralization |
| Discovery Phase 2 | Iroh DHT | Decentralized, integrates with our Merkle verification |
| Primary workload | Generic Linux shell | Not AI-specific; agents are just programs with apt |
| Economic layer | Document now, implement later | Focus on core fabric first |

---

## Getting Started (MVP)

```bash
# 1. Clone mjolnir
git clone https://github.com/identikey/mjolnir
cd mjolnir

# 2. Setup host (requires root)
sudo ./scripts/setup-host.sh

# 3. Start mjolnir
mix deps.get
iex -S mix

# 4. Spawn your first VM
iex> {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-22.04"})
iex> Mjolnir.VM.exec(vm.id, "uname -a")
{:ok, "Linux mjolnir-vm 5.10.0 ..."}

# 5. Checkpoint it
iex> {:ok, cp} = Mjolnir.Checkpoint.create(vm.id)

# 6. Spawn an AI agent
iex> {:ok, agent} = Mjolnir.Agent.spawn(:claude_code)
iex> Mjolnir.Agent.prompt(agent, "Write a hello world in Rust")
```

---

## Open Questions (Resolved)

| Question | Decision | Notes |
|----------|----------|-------|
| **Base distro** | Debian 12 | Minimal, apt-native, no Ubuntu overhead |
| **Kernel version** | 6.1 LTS | Best BTRFS, stable enough |
| **Overlay network** | Tailscale → Iroh DHT | Start easy, go masterless |
| **Master node** | None | Peer-to-peer, any node can fail |
| **Primary workload** | Shell + apt | Generic Linux; AI agents are programs |
| **Economic layer** | Document now | Implement after core fabric works |

## Remaining Open Questions

1. ~~**Guest agent**: Custom vsock daemon vs SSH vs serial console?~~
   - **Resolved**: Custom Rust guest agent (`mjolnir-agent`) via vsock. Simple JSON-RPC over vsock, starts early at `basic.target` for fast boot availability.

2. **Checkpoint storage**: Local BTRFS + Iroh (content-addressed) vs S3?
   - Leaning: Iroh for distribution, local BTRFS for active VMs

3. **GPU support**: When and how?
   - Future: VFIO passthrough or NVIDIA MIG

4. **Iroh integration**: Sidecar process vs embedded via Rustler?
   - TBD: Rustler is cleaner but more complex; sidecar is simpler to start

---

## Contributing

The project is in early design phase. Key areas needing work:

1. **Elixir core**: VM lifecycle, checkpoint coordinator
2. **BTRFS tooling**: Snapshot management, quota enforcement
3. **Firecracker integration**: Config generation, API client
4. **Agent framework**: Workspace management, channel bridging
5. **Documentation**: Architecture diagrams, API reference

See GitHub issues for specific tasks.
