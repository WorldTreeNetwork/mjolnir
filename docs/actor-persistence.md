# Actor Persistence

Mjolnir implements a **virtual actor** pattern: VMs are actors that can checkpoint their entire state to disk, disappear, and transparently reappear when a message arrives. This document explains the pattern, compares Mjolnir's approach to other systems that implement it, and discusses the design trade-offs.

---

## The Core Idea

In a traditional actor system (Erlang/OTP, Akka), actors live in memory. If the host restarts or the actor is idle, its state is gone unless the application explicitly persists it. The programmer bears the burden of serialization, storage, and rehydration.

A **virtual actor** inverts this. The runtime manages the actor's lifecycle transparently:

1. **Activation**: When a message arrives for an actor that isn't in memory, the runtime materializes it — loading state from storage, placing it in a process, and delivering the message.
2. **Deactivation**: When the actor is idle (or signals that it's done), the runtime checkpoints its state and removes it from memory.
3. **Location transparency**: Callers address actors by identity, not by process handle. The runtime resolves identity → process, activating on demand.

The caller never knows whether the actor was already running or was just woken up. From the outside, every actor appears to exist forever.

---

## How Mjolnir Implements It

Mjolnir's unit of activation is not a lightweight process — it's an entire Linux microVM. The "actor state" is the full filesystem, process tree, and memory of the guest OS.

| Concept | Mjolnir Implementation |
|---------|----------------------|
| Actor identity | VM UUID (preserved across sleep/wake cycles) |
| Actor state | BTRFS subvolume snapshot (full guest filesystem) |
| Activation table | `DormantRegistry` (ETS + JSON on disk) |
| Activation trigger | `POST /api/vms/{id}/messages` to a dormant VM |
| Deactivation trigger | Guest sends `signal_done` over vsock |
| Message queue (while deactivated) | `pending_messages` in DormantRegistry, persisted to disk |
| State checkpoint | `btrfs subvolume snapshot` (CoW reflink, near-instant) |
| State restore | `VM.spawn_with_id()` from snapshot (same UUID, same config) |

### What Makes This Unusual

Most virtual actor systems checkpoint *application-level* state — a serialized object, a row in a database, a Durable Object's SQLite. Mjolnir checkpoints the *entire compute environment*: the OS, the process tree, the filesystem, the network identity (Iroh keys). This means:

- **No serialization contract.** The guest application doesn't need to implement save/load. Its state is whatever was on disk when the snapshot happened.
- **Language-agnostic.** The guest can run Python, Rust, Node, a shell script — anything that runs on Linux. The persistence mechanism is below the application layer.
- **Full-fidelity restore.** The restored VM has the same files, the same users, the same `/tmp` contents. There's no lossy serialization step.

The cost is that activation is slower (VM boot vs. object deserialization) and the checkpoint is larger (a filesystem vs. a few KB of serialized state). This is a deliberate trade-off: Mjolnir targets workloads where the compute environment *is* the state — AI agents with tool installations, development environments, long-running analysis pipelines.

---

## Comparison with Other Systems

### Microsoft Orleans (2014)

Orleans introduced the "virtual actor" term. Actors ("grains") are C# objects activated on demand across a cluster. State is persisted to pluggable storage (Azure Tables, SQL, etc.) as serialized objects.

| Dimension | Orleans | Mjolnir |
|-----------|---------|---------|
| Actor granularity | Single C# object | Entire Linux VM |
| State size | KB (serialized fields) | GB (filesystem snapshot) |
| Activation time | Milliseconds | Seconds |
| Serialization | Explicit (grain state class) | None (BTRFS snapshot) |
| Cluster support | Built-in (silo mesh) | Single node (Iroh for addressing) |
| Language constraint | C# / .NET | Any (guest is a full Linux) |

Orleans optimizes for millions of fine-grained actors with tiny state. Mjolnir optimizes for fewer actors with rich, complex state that doesn't reduce to a serializable object.

### Cloudflare Durable Objects (2020)

Durable Objects are single-threaded JavaScript isolates with a co-located SQLite database. Each object has a unique ID, processes one request at a time, and persists between requests. Cloudflare manages placement and activation transparently.

| Dimension | Durable Objects | Mjolnir |
|-----------|----------------|---------|
| Actor granularity | JS isolate + SQLite | Linux VM + filesystem |
| State model | Explicit (SQLite writes) | Implicit (filesystem snapshot) |
| Activation time | ~50ms (cold start) | ~2-5s (VM boot from snapshot) |
| Concurrency | Single-threaded per object | Full Linux process tree |
| Network model | Anycast + smart placement | Iroh QUIC (NAT-traversing P2P) |
| Hosting | Cloudflare's edge network | Self-hosted bare metal |

Durable Objects and Mjolnir solve related problems at different layers. A Durable Object is a coordination primitive (chat room, rate limiter, game session). A Mjolnir VM is a compute environment (AI agent workspace, dev environment, pipeline stage). You might use a Durable Object to *route messages to* a Mjolnir VM.

### Erlang/OTP (Process Hibernation)

Erlang processes can hibernate (`proc_lib:hibernate/3`), which garbage-collects the process heap down to a minimal continuation. The process stays in the scheduler's table but consumes almost no memory until a message arrives.

| Dimension | Erlang Hibernate | Mjolnir Dormancy |
|-----------|-----------------|-----------------|
| What's preserved | Process heap + mailbox | Full VM filesystem |
| Memory during sleep | Minimal (~300 bytes) | Zero (process stopped entirely) |
| Wake trigger | Any message to the PID | `deliver_message` API call |
| State location | In-memory (same node) | On-disk (BTRFS snapshot) |
| Survives host restart | No | Yes |

Erlang hibernation is the closest spiritual ancestor. Mjolnir extends the idea from a single process to an entire operating system, and from in-memory to durable storage.

### Unikernels (MirageOS, NanoVMs)

Unikernels compile an application into a single-purpose VM image with no general-purpose OS. Some unikernel runtimes (notably MirageOS on Xen) support snapshotting and migration.

| Dimension | Unikernels | Mjolnir |
|-----------|-----------|---------|
| Guest model | Single-purpose image | General-purpose Linux |
| Snapshot scope | VM memory + disk | Filesystem only (no memory snapshot) |
| Restore fidelity | Full (memory + execution state) | Filesystem only (processes restart) |
| Flexibility | Compile-time fixed | Runtime-configurable |

Unikernel snapshots are more faithful (they capture in-flight execution state), but require building a custom image per application. Mjolnir trades memory-snapshot fidelity for the flexibility of running anything that runs on Linux.

---

## Design Consequences

### The VM is the Serialization Format

In most actor systems, the programmer defines what state to persist and how to serialize it. This is a constant source of bugs: schema evolution, missing fields, circular references, non-serializable handles.

Mjolnir sidesteps this entirely. The "serialized state" is a BTRFS snapshot — a frozen copy of the filesystem at a point in time. There's no schema, no versioning, no serialization library. The trade-off is granularity: you can't partially restore or merge state from two snapshots the way you could with a structured state object.

### Activation Cost Shapes the Use Case

Orleans activates grains in milliseconds. Durable Objects in tens of milliseconds. Mjolnir activates VMs in seconds. This rules out use cases where activation latency is on the critical path (e.g., per-HTTP-request activation for a web app).

Where it works well: workloads that are **bursty and stateful** — an AI agent that works for minutes then sleeps for hours, a CI pipeline stage that runs on demand, a development environment that persists between sessions. The seconds of activation cost are amortized over minutes or hours of work.

### Identity Preservation Enables Addressing

The restored VM gets the same UUID. This means external systems that reference the VM by ID don't need to update their pointers after a sleep/wake cycle. Iroh connection tickets, API URLs, webhook targets — all remain valid across dormancy. This is what makes the activation transparent to callers.

### Message Queue as Activation Signal

The DormantRegistry's `pending_messages` queue serves double duty: it buffers messages during the restore window, and the act of enqueuing a message is what triggers restoration. There's no separate "activate" API — activation is an emergent consequence of messaging. This keeps the API surface simple (just `deliver_message`) and makes the system self-healing: if something needs a dormant VM, it just talks to it.

---

## Where This Is Going

The current implementation is single-node: VMs sleep and wake on the same host. The natural extension is **distributed activation** — a cluster-wide DormantRegistry where a message can activate a VM on whichever node has capacity, with the snapshot transferred via `btrfs send | btrfs receive` or pulled over Iroh. This would make Mjolnir a true distributed virtual actor runtime, where VMs float between physical hosts based on demand.

The mailbox that triggers activation should travel **with the actor**,
not sit in a cluster-wide queue. Placement (which host owns this VM)
is a small derived index; the ledger is `@mail/<vm_id>/` on that host.
Argument: [`philosophy/mailbox-as-spool.md`](philosophy/mailbox-as-spool.md).

See also:

- `docs/vm-messaging.md` — API reference for the messaging and dormancy system
- `docs/computational-fabric.md` — the broader vision for distributed compute
- `docs/plans/durability.md` — crash resilience and state recovery design
- `docs/philosophy/mailbox-as-spool.md` — retry-safe spool; not built
