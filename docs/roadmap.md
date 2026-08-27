# Mjolnir Project Roadmap
## From Theory to Distributed Computation Fabric

> **How to read this.** This roadmap was originally written as a forward-looking,
> Firecracker-era plan. It has been rewritten to reflect reality: Mjolnir now runs on **Cloud
> Hypervisor v50 with virtio-fs + BTRFS subvolumes** (no ext4 images, no Firecracker), and much
> of the original Phase 1–3 plan has shipped. Sections are now organized as **Shipped**,
> **In progress**, and **Planned** rather than as a fictional weekly timeline. For the current
> architecture see [`../CLAUDE.md`](../CLAUDE.md) and [`architecture.md`](architecture.md); for a
> dated implementation snapshot see [`plans/current-status.md`](plans/current-status.md).

### Vision

Mjolnir is a distributed computational fabric where:
- **Any Linux shell** can be spawned on-demand as an isolated microVM
- **State is orthogonally persistent** — checkpoint, migrate, resume anywhere
- **AI agents** run with full system access, safely sandboxed
- **Channels** (π-calculus style) connect processes across the network
- **Economic incentives** enable a decentralized compute marketplace

The first three of those are real today (single-node); the last two are the longer-term
direction.

---

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 5: Applications                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │ AI Agents   │  │ Dev Envs    │  │ CI Jobs     │                 │
│  │ (Claude)    │  │ (ephemeral) │  │ (Forgejo)   │                 │
│  └─────────────┘  └─────────────┘  └─────────────┘                 │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 4: Agent & Workflow Orchestration    [computational-fabric]  │
│  - Multi-agent choreography                  (planned)              │
│  - Cross-org trust & authentication                                 │
│  - Capability marketplace                    (planned)              │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 3: Type Sync & Messaging             [spec.md]               │
│  - Universal Type Descriptors                                       │
│  - Transport abstraction (HTTP, WS, Iroh QUIC)                     │
│  - Channel routing (fan-out, pub-sub, round-robin)  (partial)      │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 2: MicroVM Execution Fabric          [microvm-fabric.md]     │
│  - Cloud Hypervisor VM management            ✅ shipped             │
│  - BTRFS subvolume checkpointing             ✅ shipped             │
│  - Elixir/OTP orchestration                  ✅ shipped             │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 1: Theoretical Foundations           [everything-is-a-channel]│
│  - π-calculus (remote closures)             [orthogonal-persistence]│
│  - ρ-calculus (service discovery)           [event-queue]           │
│  - Cryptographic identity                    ✅ per-VM Ed25519/Iroh  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Shipped (single-node)

These work end-to-end today. Drive them from the `mj` CLI or the HTTP API.

### VM lifecycle
- Spawn microVMs on **Cloud Hypervisor v50** with a PVH kernel, booting in well under a second.
- `spawn` → `exec` → `connect` → `snapshot` → `stop`/`kill`, all via `Mjolnir.VM` (a GenServer
  per VM under a DynamicSupervisor) and the HTTP API.
- Rust **guest agent** over vsock: `exec`, `ping`, network/identity/Iroh configuration, PTY
  sessions, and LUKS2 secret injection.

### Storage (BTRFS + virtio-fs)
- Base images are **BTRFS subvolumes** under `@base/`, shared into the guest directly via
  **virtio-fs** — no ext4 block images.
- Instant copy-on-write cloning via `btrfs subvolume snapshot` (`Mjolnir.BTRFS.clone/2`): a
  ~1ms metadata operation regardless of filesystem size.
- Named snapshots (`@snapshots/<name>/`) of running VMs, quiesced for consistency
  (guest `sync` → pause → host fsync → snapshot → resume). Spawn fresh VMs from any snapshot.

### Connectivity (Iroh)
- Per-VM cryptographic identity (Ed25519) and NAT-traversing **Iroh QUIC** access:
  `mj connect <ticket>` for an interactive PTY — no port-forwarding, no public IP.
- WebSocket PTY (`mj connect <vm_id>`) for shells over the API, including reattachable
  `--session` (tmux) sessions.

### Secrets
- **Deploy secrets (web apps):** `mj secrets set <app> KEY` merges
  `/var/lib/mjolnir/deploy/secrets/<slug>.json`. `mj deploy` injects that map
  at service-VM spawn (`secrets_mode: :managed`). Names only on `mj secrets ls`.
  See [Deploying a Web App](guide/deploying-an-app.md#secrets-stay-out-of-the-snapshot).
- **LUKS2-encrypted volumes** inside the guest, with passphrases delivered over a
  dedicated Iroh ALPN that bypasses the host. Authorized inject peers validated by node ID.
  Every `exec` auto-sources `/run/mjolnir/secrets.env` (tmpfs — plaintext never hits the rootfs).

### Dormancy & messaging
- Dormant VMs: `handle_done/1` snapshots a VM and registers it for wake-on-message
  (`Mjolnir.DormantRegistry`). Inter-VM messaging buffered during boot.

### CI: VM-sandboxed Forgejo runner
- A forked `forgejo-runner` executes Actions workflows **inside Mjolnir microVMs** instead of
  Docker containers (`lib/mjolnir/runner/` here; the runner itself is the `identikey/forgejo-runner`
  repo, branch `mjolnir`). Multi-virtio-fs mounts let CI mount a repo read-only into the VM.

### Host config: Forge
- `Mjolnir.Forge` — a declarative host-configuration reconciler with three-way diff
  (declared/owned/observed), ownership-tracked pruning, an audit log + SSE event stream, and a
  ratatui TUI (`mj forge tui`).

### Persistence index: Postgres sidecar
- An OTP-managed Postgres (Erlang Port, Unix-socket peer auth) holding **derived indexes**
  rebuildable from the filesystem source of truth (signed envelopes + content-addressed blobs).

### Tooling
- The `mj`/`mjolnir` CLI (spawn, exec, connect, iroh, snapshot, forge, mcp-serve), the `just`
  control plane, and a ~613-test suite (`mix test`) with integration/postgres/e2e tags.

---

## In progress / near-term

- **Memory + CPU snapshots** (true orthogonal persistence): pause/resume of full VM state via
  Cloud Hypervisor's native snapshot API. Today's checkpoints are filesystem-only. See
  [orthogonal-persistence.md](orthogonal-persistence.md).
- **Content-addressed checkpoint distribution**: store snapshots as Iroh collections
  (BLAKE3-verified, deduplicated) so they can move between hosts. Groundwork exists in the
  storage design; see [`plans/initramfs-verified-boot.md`](plans/initramfs-verified-boot.md).
- **Index backfill / hot-serve**: rebuild Postgres indexes from disk and short-circuit hot
  reads through them with a SecretStore fallback.

---

## Planned / longer-term

The multi-node and ecosystem layers are not built yet — Mjolnir is currently single-node.

### Distribution
- Multi-node Elixir cluster (libcluster), distributed VM registry, and a placement scheduler.
- Cross-node **migration**: cold migration first (stop → `btrfs send/receive` → start over
  Iroh), live migration later (using memory snapshots).
- Masterless discovery via Iroh DHT instead of any central coordinator.

### Channels & workflows
- `Mjolnir.Channel` — π-calculus-inspired message channels (local + distributed routing,
  channel passing) connecting processes across the fabric.
- Multi-agent workflow choreography with atomic checkpointing across participating VMs.

### Production & ecosystem
- Observability (Prometheus/OpenTelemetry), reliability automation (auto-restart, node-failure
  recovery, BTRFS scrub/balance), a web dashboard, GPU passthrough (VFIO), and — furthest out —
  an economic layer (resource accounting, capability marketplace, operator incentives).

---

## Tech Stack Summary

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **Virtualization** | Cloud Hypervisor v50 | virtio-fs, BTRFS subvolumes, PVH boot. (Firecracker was removed — no virtio-fs.) |
| **Guest OS** | Ubuntu 24.04 (default base) | apt-native; Arch base also buildable. |
| **Filesystem** | BTRFS subvolumes | Instant CoW clones via `btrfs subvolume snapshot`; `send/receive` for future migration; compression. |
| **Guest↔host control** | vsock + Rust guest agent | Low-latency, no network dependency for control plane. |
| **Orchestration** | Elixir/OTP | Supervision trees, crash isolation (hypervisor as a Port), message-passing. |
| **Connectivity** | Iroh QUIC | NAT-traversing P2P shells/SSH; per-VM Ed25519 identity; content-addressed transfer. |
| **Persistence index** | Postgres (sidecar) | Derived, rebuildable indexes over an FS source of truth. |
| **Workload** | Shell + apt | Run any Linux program; AI agents and CI jobs are just use cases. |

---

## Document Index

| Document | Layer | Description | Status |
|----------|-------|-------------|--------|
| [computational-fabric.md](computational-fabric.md) | Theory | π/ρ-calculus, crypto identity, MCP integration, economic layer | Draft |
| [spec.md](spec.md) | Messaging | Type synchronization, transport abstraction, routing patterns | Draft |
| [microvm-fabric.md](microvm-fabric.md) | Execution | Cloud Hypervisor + BTRFS + Elixir + Iroh implementation | Current |
| [architecture.md](architecture.md) | Execution | Module-level architecture of the current system | Current |
| [orthogonal-persistence.md](orthogonal-persistence.md) | Pattern | Checkpoint/restore semantics, process-calculus mapping | Draft |
| [everything-is-a-channel.md](everything-is-a-channel.md) | Philosophy | Channels as universal primitive | Notes |
| [event-queue.md](event-queue.md) | Notes | Email as robust event queue, TCP/UART streams | Notes |
| [philosophy/](philosophy/) | Philosophy | Speculative architecture; mailbox-as-spool | Notes |
| [openspec/specs/vm-mailbox/](../openspec/specs/vm-mailbox/spec.md) | Messaging | Retry-safe per-actor spool (ADR 0006) | Current |
| [guide/](guide/) | User | Hands-on guides: getting started, snapshots, coming from Docker | Current |
| [roadmap.md](roadmap.md) | Meta | This document | Active |

---

## Getting started

The fastest path is the user [Guide](guide/getting-started.md). In brief:

```bash
# Install the CLI (needs Rust), then point it at a server
./scripts/build-client.sh --install
mj login --api https://mjolnir.example.com

# Spawn a VM and drop into a shell
mj spawn --connect

# Run a command, snapshot, and spin a fresh VM from the saved state
mj exec <vm_id> "uname -a"
mj snapshot <vm_id> my-env
mj spawn --snapshot my-env
```

To stand up your own server (Linux + KVM required), see
[Run your own server](../README.md#run-your-own-server).

---

## Resolved design questions

| Question | Decision |
|----------|----------|
| Hypervisor | **Cloud Hypervisor v50** (virtio-fs + BTRFS subvolumes). Firecracker removed — no virtio-fs. |
| Storage model | BTRFS subvolumes shared via virtio-fs; CoW clones via `btrfs subvolume snapshot`. No ext4 images. |
| Guest agent | Custom Rust daemon over vsock (JSON control on channel 0, binary PTY/syslog on others). |
| Connectivity | Iroh QUIC for masterless, NAT-traversing P2P access; per-VM Ed25519 identity. |
| Base distro | Ubuntu 24.04 default (Arch base also buildable). |
| Master node | None — peer-to-peer is the long-term target; single-node today. |

### Still open

1. **Checkpoint storage**: local BTRFS for active VMs + Iroh (content-addressed) for
   distribution vs. an object store — leaning Iroh.
2. **GPU support**: VFIO passthrough or MIG; timing TBD.
3. **Live migration**: depends on memory-snapshot work landing first.

---

## Contributing

Active areas needing work:

1. **Distribution** — multi-node cluster, scheduler, cross-node migration.
2. **Orthogonal persistence** — memory+CPU snapshots via Cloud Hypervisor.
3. **Checkpoint distribution** — Iroh content-addressed snapshot store with BLAKE3 verification.
4. **Channels & workflows** — `Mjolnir.Channel` and multi-agent choreography.
5. **Docs** — keep architecture references in sync with the code.

See the beads issue tracker (`bd ready`) for specific tasks.
