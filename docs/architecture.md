# Mjolnir Architecture

## What Mjolnir Is

Mjolnir is a distributed computational fabric for spawning lightweight Linux shells as isolated microVMs. Each VM boots in under a second, gets its own filesystem via instant copy-on-write cloning, and is reachable from anywhere in the world through NAT-traversing encrypted connections.

**Default hypervisor: Cloud Hypervisor v50.0** (transitioned from Firecracker in Feb 2026). Cloud Hypervisor is the active backend. Firecracker is retained in the codebase for reference but is deprecated and no longer actively maintained.

The goal: lightweight micro-VMs that spin up fast, have snapshotted filesystems, synchronize across devices, rehydrate easily, work behind any NAT, and can communicate with each other.

---

## System Diagram

```
                                 The Internet
                                      |
                                  Iroh Relay
                                 /    |    \
                                /     |     \
                    +-----------+     |     +-----------+
                    |  macOS    |     |     |  Linux    |
                    |  Laptop   |     |     |  Server   |
                    |           |     |     |           |
                    | mjolnir   |     |     | Elixir    |
                    | (client)  |     |     | OTP App   |
                    +-----------+     |     +-----------+
                         |            |           |
                         |      QUIC/Iroh    Cloud Hypervisor
                         |            |           |
                         +-----+------+     +-----+-----+-----+
                               |            |     |     |     |
                               |          +---+ +---+ +---+ +---+
                               +--------->|VM1| |VM2| |VM3| |VM4|
                                          |   | |   | |   | |   |
                                          +---+ +---+ +---+ +---+
                                           TAP   TAP   TAP   TAP
                                          10.200.0.x each
```

---

## Component Overview

Mjolnir has four major layers, each implemented in the language best suited to it:

```
+---------------------------------------------------------------+
|  CLIENT LAYER (Rust)                                          |
|  mjolnir CLI - connects to VMs from any device, any network  |
+---------------------------------------------------------------+
        |  Iroh QUIC (binary frames)
+---------------------------------------------------------------+
|  GUEST LAYER (Rust)                                           |
|  mjolnir-agent - runs inside each VM                          |
|  - vsock listener (host commands)                             |
|  - Iroh endpoint (remote shell access)                        |
|  - PTY management (terminal sessions)                         |
|  - LUKS secrets engine (encrypted env vars)                   |
+---------------------------------------------------------------+
        |  vsock + TAP networking
+---------------------------------------------------------------+
|  ORCHESTRATION LAYER (Elixir/OTP)                             |
|  - VM lifecycle management (GenServer per VM)                 |
|  - DynamicSupervisor for fault isolation                      |
|  - HTTP API with JWT authentication                           |
|  - BTRFS filesystem operations                                |
|  - Network management (TAP + routing)                         |
+---------------------------------------------------------------+
        |  Cloud Hypervisor REST API over Unix socket
+---------------------------------------------------------------+
|  HYPERVISOR LAYER (Cloud Hypervisor, primary)                 |
|  - KVM-based microVM isolation                                |
|  - ~5MB memory overhead per VM                                |
|  - BTRFS subvolumes shared into VM via virtio-fs              |
|  - Mjolnir.Hypervisor behaviour (Firecracker deprecated)      |
+---------------------------------------------------------------+
```

---

## How It All Fits Together

### Spawning a VM

When you request a new VM, this is what happens:

```
HTTP POST /api/vms
         |
         v
  +------------------+
  |  Elixir Router   |  Verify JWT, check vms:spawn scope
  +------------------+
         |
         v
  +------------------+
  |  Mjolnir.VM      |  GenServer started under DynamicSupervisor
  |  GenServer.init   |  Registered in VMRegistry by UUID
  +------------------+
         |
         v  (handle_continue :boot — async, doesn't block caller)
         |
    +----+----+
    |         |
    v         v
 BTRFS     Network
 clone     create_tap
    |         |
    |    +----+----+
    |    |         |
    |    v         v
    | TAP dev   IP route
    | mj-xxxx   10.200.0.x/32
    |    |         |
    +----+---------+
         |
         v
  +------------------+
  | Port.open        |  Start cloud-hypervisor binary as OS process
  | cloud-hypervisor |  Crash-isolated: if it dies, Elixir knows
  +------------------+
         |
         v
  +------------------+
  | Cloud Hypervisor |  Configure via REST API over Unix socket:
  | REST API         |  - kernel (PVH), virtio-fs mount, vCPU/memory
  +------------------+  - vsock, network interface
         |              - vm.create then vm.boot
         v
  +------------------+
  | Guest boots      |  ~200ms kernel + ~300ms userspace
  | mjolnir-agent    |  Starts at basic.target (early boot)
  | comes up         |  Listens on vsock port 5000
  +------------------+
         |
         v
  +------------------+
  | Host pings       |  Vsock CONNECT 5000 -> ping/pong
  | guest agent      |  Confirms agent is alive
  +------------------+
         |
         v
  +------------------+
  | Configure        |  Send IP address to guest agent
  | guest network    |  Agent runs mjolnir-network-setup script
  +------------------+
         |
         v
  +------------------+
  | Iroh endpoint    |  Guest agent connects to Iroh relay
  | comes online     |  Generates ticket (serialized EndpointAddr)
  | (async, 2-5s)    |  Reports ready to host via get_iroh_status
  +------------------+
         |
         v
  VM is running. Shell reachable via Iroh from anywhere.
```

### Connecting to a Shell

From any device on any network:

```
$ mjolnir connect '<ticket>'
         |
         v
  +------------------+
  | Parse ticket     |  Deserialize iroh EndpointAddr from JSON
  | Create endpoint  |  Ephemeral Iroh identity (no key saved)
  +------------------+
         |
         v
  +------------------+
  | Iroh relay       |  QUIC connection via relay (or direct
  | connection       |  if hole-punching succeeds — ~500ms)
  +------------------+
         |
         v
  +------------------+
  | ALPN handshake   |  Protocol: "mjolnir-shell/1"
  | Open bi-stream   |  Bidirectional QUIC stream
  +------------------+
         |
         v
  +------------------+
  | Send Hello       |  Client terminal size (rows, cols)
  | frame            |  Protocol version
  +------------------+
         |
         v
  +------------------+
  | Guest spawns     |  /bin/bash in PTY with client's
  | PTY session      |  terminal dimensions
  +------------------+
         |
         v
  +------------------+
  | Bidirectional    |  stdin -> Data frames -> PTY stdin
  | frame bridge     |  PTY stdout -> Data frames -> stdout
  |                  |  SIGWINCH -> Resize frames -> ioctl
  +------------------+
         |
         v
  Interactive shell session. Full TUI support (vim, htop, etc).
```

### Foreign-origin web terminals (ADR 0004)

A browser cannot set `Authorization` on `new WebSocket(...)`.
Mjolnir's hosted `/term/:id` stashes a JWT in the `mj_term` cookie
for the **API origin**. A dashboard on another host does not get
that cookie.

Those terminals terminate on a trusted Linux box. The box runs
`mj connect <vm_id>` against the existing hop
`wss://<api>/api/vms/:id/pty` (binary = PTY bytes, text = resize
JSON). The JWT stays in `mj`'s token store. First surface: xibu
`/devterm4` (ttyd wrapping `mj connect`). See
[`openspec/specs/web-pty-edge/spec.md`](../openspec/specs/web-pty-edge/spec.md).

### Executing Commands (Non-Interactive)

For scripted operations, the vsock path is faster:

```
HTTP POST /api/vms/:id/exec {"command": "apt install -y nginx"}
         |
         v
  +------------------+
  | Vsock.Connection |  Connect to Cloud Hypervisor vsock UDS
  | GenServer        |  Send "CONNECT 5000\n", wait for "OK"
  +------------------+
         |
         v
  +------------------+
  | Length-prefixed   |  [4 bytes length][JSON body]
  | JSON message     |  {type: "exec", id: UUID, command: "..."}
  +------------------+
         |
         v
  +------------------+
  | Guest agent      |  sh -c "apt install -y nginx"
  | executes         |  Captures stdout, stderr, exit_code
  +------------------+
         |
         v
  +------------------+
  | Response         |  {type: "exec_response", stdout: "...",
  | returned         |   stderr: "...", exit_code: 0}
  +------------------+
```

---

## The Components in Detail

### Elixir Supervision Tree

```
Mjolnir.Application (one_for_one)
|
+-- Mjolnir.Cleanup
|   Sweeps orphan hypervisor processes, stale TAPs, sockets on startup
|
+-- Mjolnir.EventBus
|   Pub/sub for VM lifecycle events (:vm_started, :vm_stopped, :vm_dormant)
|
+-- Mjolnir.VMRegistry
|   Registry mapping vm_id (UUID) -> GenServer PID
|   Enables {:via, Registry, {VMRegistry, id}} lookups
|
+-- Mjolnir.DormantRegistry
|   ETS table for dormant VM metadata (snapshot name, original config)
|
+-- Mjolnir.VMSupervisor (DynamicSupervisor)
|   Spawns VM GenServers on demand
|   |
|   +-- Mjolnir.VM (transient, per-VM GenServer)
|   |   Owns: hypervisor Port, sockets, rootfs, TAP device
|   |   States: :booting -> :running -> :stopped/:dormant (:failed on boot error)
|   |
|   +-- Mjolnir.VM (another VM...)
|   +-- ...
|
+-- Mjolnir.Auth.KeycloakStrategy (optional)
|   JWKS key fetcher for JWT verification
|   Only started when OIDC issuer is configured
|
+-- Bandit HTTP Server
    Serves Mjolnir.API.Router on configured port (default 4000)
```

`Mjolnir.Cleanup` is a supervised process that runs `sweep/0` at startup to kill orphaned Cloud Hypervisor processes (and any legacy Firecracker processes from prior deployments), clean stale TAP devices, and remove leftover sockets/directories from previous crashes.

Each VM is a GenServer that owns its hypervisor process as a Port. If the hypervisor crashes, the Port sends an exit signal, and the GenServer cleans up (TAP device, routes, sockets, rootfs). Transient restart means VMs exit `:normal` on boot failure (preventing restart loops) — they're intentionally ephemeral.

### Rust Guest Agent

The guest agent binary (`mjolnir-agent`) runs inside every VM and serves two concurrent subsystems:

```
mjolnir-agent (tokio runtime)
|
+-- Vsock Listener (port 5000)
|   Synchronous request/response over vsock
|   |
|   +-- exec: run shell commands
|   +-- ping: health check
|   +-- configure_network: set IP address
|   +-- get_iroh_status: report shell readiness
|
+-- Iroh Shell Server
    Asynchronous interactive shells over QUIC
    |
    +-- Loads/generates persistent Ed25519 keypair
    +-- Binds Iroh Endpoint with ALPN "mjolnir-shell/1"
    +-- Connects to relay (makes VM globally reachable)
    +-- Accepts incoming connections
    +-- Per-connection: PTY spawn + frame bridge
```

Communication between the two subsystems uses a `tokio::sync::oneshot` channel: when Iroh comes online, it sends its ticket to the vsock listener so the host can query it.

### Shared Wire Protocol (mjolnir_protocol)

The shell protocol uses binary framing instead of JSON for efficiency:

```
Frame format:
+------+-------------------+-------------------+
| Type | Payload Length    | Payload           |
| 1B   | 4B (big-endian)  | N bytes           |
+------+-------------------+-------------------+

Message Types:
  0x01 Data    [N bytes: raw terminal data]
  0x02 Resize  [2B rows + 2B cols, big-endian]
  0x03 Exit    [4B exit code, big-endian, signed]
  0x04 Hello   [2B rows + 2B cols + 2B protocol version]
```

A keystroke round-trip is 6 bytes in each direction (1 type + 4 length + 1 char). Compare with the old JSON protocol where `{"type":"data","payload":[107]}` was 30+ bytes, and `Vec<u8>` was serialized as an array of integers (`[104,101,108,108,111]` for "hello").

### Client Binary (mjolnir)

The client is a standalone Rust binary that runs on the user's machine (macOS or Linux):

```
mjolnir connect '<ticket>'       Direct Iroh connection
mjolnir shell <vm-id> --api URL  Fetch ticket from API, then connect

Connection sequence:
1. Parse EndpointAddr from ticket JSON
2. Create ephemeral Iroh Endpoint (no persisted key)
3. Connect to VM via relay (or direct hole-punch)
4. Open bidirectional QUIC stream
5. Send Hello frame with terminal dimensions
6. Set terminal to raw mode
7. select! loop: stdin <-> frames <-> stdout
8. Handle SIGWINCH -> Resize frames
9. On disconnect: restore terminal, exit
```

### Networking

Each VM gets a TAP interface with /32 point-to-point routing:

```
Host kernel (IP forwarding enabled)
+-- iptables MASQUERADE on outbound interface
|
+-- TAP mj-a1b2c3d4 (no IP assigned)
|   Route: 10.200.0.47/32 dev mj-a1b2c3d4
|   Proxy ARP enabled
|   +-- VM 1: eth0 = 10.200.0.47/32
|       Default route dev eth0 (point-to-point, no gateway)
|
+-- TAP mj-e5f6g7h8 (no IP assigned)
    Route: 10.200.0.183/32 dev mj-e5f6g7h8
    +-- VM 2: eth0 = 10.200.0.183/32

Subnet: 10.200.0.0/10 (~4 million addresses)
IPs: deterministic hash of vm_id (stable across reboots)
MACs: 02:FC:00:xx:xx:xx from SHA256(vm_id)
```

No bridge device needed. Each VM has its own TAP with a /32 route. The host acts as a router, not a switch. This is simpler and more scalable than bridged networking.

### Filesystem

```
BTRFS filesystem (virtio-fs + BTRFS subvolumes)
|
+-- @base/                  Declared OS-root catalog (ADR 0009)
|   ubuntu-24.04/           Default for mj spawn (deploy default waits on remove-deploy-node-bun)
|   ci-ubuntu-24.04/        Forgejo runner
|   buzz-agent/             Bodies
|   arch/                   Optional; not a default
|
+-- @vms/
|   {vm-uuid}/              Per-VM rootfs (BTRFS subvolume, CoW clone of base)
|                           Shared with guest via virtio-fs (virtiofsd vhost-user socket)
|                           Mounted in guest as: root=myfs rootfstype=virtiofs rw
|
+-- @snapshots/
    {name}/                 Named filesystem snapshots (BTRFS subvolume clones)
    {name}.mem/             Memory-park artifacts (`state.json` + RAM) when kind is memory
```

`@base/` is a **declared catalog of OS roots**, not a pile of
toolchain images. Pins vs aliases, unmanaged names, and rebuild
rules: [`docs/decisions/0009-base-image-catalog.md`](decisions/0009-base-image-catalog.md)
(ADR 0009; `add-base-images` folded 2026-09-10). Living spec:
[`openspec/specs/base-images/spec.md`](../openspec/specs/base-images/spec.md).
Toolchains live in `mise` layers or snapshots, not extra `@base/`
debootstraps. `deploy-node-bun` is retired by
`remove-deploy-node-bun` (not this pointer).

A **Honor being** is a long-lived vibe-coder VM: a *device* of a
friend's C2 identikey (`credentials.kind = ssh_git`), not a new
`@base/` name. ADR
[`0011`](decisions/0011-honor-being.md) (`add-honor-being`, advise
accept 2026-09-10). Passkey at `auth.identikey.me` gates wrug
`/term`; grok uses `XAI_API_KEY` in tmpfs; git is SSH-signed from
opaque inject; write remote is Forgejo on mimir. Living spec waits
on implement landings (`add-identikey-being-client`,
`add-vm-git-subkey`, `add-honor-git-remote`,
`add-honor-dev-preview`, `update-hypersigil-store-cors`).

Why virtio-fs + BTRFS subvolumes? Cloud Hypervisor supports virtio-fs, which lets the host share a directory tree directly into the guest without a block device. BTRFS subvolumes give us O(1) copy-on-write cloning (via `btrfs subvolume snapshot`), so VM creation is instant regardless of rootfs size, and storage is efficiently shared until pages diverge.

Previously (when Firecracker was the hypervisor), the storage strategy was ext4-on-BTRFS: ext4 image files stored on a BTRFS filesystem, cloned with `cp --reflink`. Firecracker needed a block device image and didn't support virtio-fs. That strategy still works but is no longer used.

### HTTP API

```
GET  /api/health                    No auth required
POST /api/vms                       [vms:spawn]    Spawn VM
GET  /api/vms                       [vms:read]     List VMs
GET  /api/vms/:id                   [vms:read]     VM status
POST /api/vms/:id/exec              [vms:exec]     Run command
DELETE /api/vms/:id                 [vms:stop]     Stop VM
GET  /api/vms/:id/ticket            [shell:connect] Iroh ticket
GET  /api/vms/:id/node-id           [shell:connect] Iroh node ID
POST /api/vms/:id/await-shell       [shell:connect] Wait for shell
POST /api/vms/:id/snapshots         [snapshots:create] Filesystem snapshot (VM keeps serving)
POST /api/vms/:id/freeze            [snapshots:create] Memory park; source VMM torn down
GET  /api/snapshots                 [snapshots:read]  List (`kind`: filesystem | memory)
GET  /api/snapshots/:name           [snapshots:read]  Show (`kind`)
POST /api/snapshots/:name/thaw      [vms:spawn]    Restore memory snapshot to source_vm_id
```

Authentication: JWT bearer tokens with scope-based authorization. Scopes are space-separated strings in the token claims. Localhost bypass available for development.

---

## Technical Choices and Their Benefits

### Cloud Hypervisor (microVMs, not containers)

| What we get | Why it matters |
|-------------|----------------|
| KVM-based hardware isolation | Each VM is a real virtual machine, not a container. Full kernel isolation. |
| ~125ms boot, ~5MB overhead | VMs feel instant. Can run hundreds on a single host. |
| Minimal device model | Reduced attack surface. No PCI, no USB, no GPU — just virtio. |
| virtio-fs for rootfs sharing | BTRFS subvolumes mounted directly into guests. No ext4 image files. |
| Native snapshotting | `mj freeze` parks RAM+fs and tears the source VMM down (`vm.snapshot` is terminal for virtio-fs). `mj thaw` restores the same VM id. |
| vsock for host-guest | Direct communication without networking. Low latency, no TCP overhead. |

Docker gives you process isolation (cgroups + namespaces). Cloud Hypervisor gives you hardware isolation (KVM + reduced VMM). For running untrusted code — especially AI agents with full system access — hardware isolation is non-negotiable.

Firecracker was the original hypervisor backend (deprecated Feb 2026). It lacks virtio-fs support, which is required for the current BTRFS subvolume storage architecture. The Firecracker modules are retained in the codebase for reference.

### BTRFS with reflink (not overlayfs, not ZFS)

| What we get | Why it matters |
|-------------|----------------|
| O(1) CoW file cloning | Spawn a VM in microseconds regardless of image size. |
| Storage deduplication | 100 VMs from the same base share blocks until they diverge. |
| send/receive for migration | Efficiently transfer filesystem deltas between hosts. |
| Compression (zstd) | 30-50% space savings on typical Linux rootfs. |
| Linux-native | No licensing concerns (unlike ZFS). Mainline kernel support. |

overlayfs is great for containers but doesn't compose well with virtio-fs shared directories — changes from the guest don't always propagate correctly back to the host layer. ZFS has the same CoW features but isn't in the mainline kernel and has CDDL licensing complexity. BTRFS gives us everything we need and is a first-class Linux citizen.

### Elixir/OTP (not Go, not Python)

| What we get | Why it matters |
|-------------|----------------|
| Supervision trees | If a VM process crashes, only that VM is affected. Automatic cleanup. |
| GenServer per VM | Each VM has its own isolated state, mailbox, and lifecycle. |
| Registry for lookup | O(1) VM lookup by UUID without a separate database. |
| Distributed by default | Erlang distribution connects **hosts we operate**. Guests stay off the cluster (vsock / Iroh / gateway). See [`openspec/specs/buzz-local-client/spec.md`](../openspec/specs/buzz-local-client/spec.md). |
| Hot code reloading | Update orchestration logic without stopping running VMs. |
| Pattern matching | Clean protocol handling for vsock message parsing. |

The actor model maps perfectly to VM management: each VM is an actor with its own state and lifecycle. OTP supervision handles the exact failure modes we care about (hypervisor crash, network timeout, boot failure).

### Iroh (not Tailscale, not WireGuard, not SSH)

| What we get | Why it matters |
|-------------|----------------|
| NAT traversal | VMs reachable from anywhere — home WiFi, cellular, corporate networks. |
| No central server | Relay is optional. Direct hole-punching when possible. |
| Per-VM identity | Each VM has its own Ed25519 keypair. No shared credentials. |
| QUIC transport | Multiplexed streams, 0-RTT reconnection, built-in encryption. |
| Content addressing | Future: distribute VM snapshots by content hash. |

Every VM is a first-class peer on the network with its own cryptographic identity. This is fundamentally different from SSH (which requires sshd + key management) or Tailscale (which requires a coordination server and account). A VM can be reached by anyone who has its ticket, from anywhere.

### Rust for guest agent and client (not Go, not C)

| What we get | Why it matters |
|-------------|----------------|
| Static musl binary | Single file, no runtime dependencies. Works in minimal rootfs. |
| async/await (tokio) | Concurrent vsock + Iroh + PTY without threads. |
| Memory safety | No buffer overflows in the code running inside every VM. |
| Shared protocol crate | Guest agent and client use identical frame codec. No version skew. |
| Small binary size | ~25MB with Iroh. Compare with Go (~30-50MB with similar deps). |

### /32 point-to-point routing (not bridge, not macvlan)

| What we get | Why it matters |
|-------------|----------------|
| No bridge device | Simpler. No STP, no broadcast domain, no ARP storms. |
| Per-VM isolation | VMs can't see each other's traffic by default. |
| Scalable | Adding a VM is one route entry, not a bridge port. |
| Deterministic IPs | Hash-based allocation is stable across reboots. |
| Simple NAT | One iptables MASQUERADE rule for outbound. |

### Binary frame protocol (not JSON, not protobuf)

| What we get | Why it matters |
|-------------|----------------|
| 6 bytes per keystroke | vs 30+ bytes with JSON. 5x less bandwidth for interactive use. |
| Proper message framing | No split-message bugs. Length-prefixed = read exactly N bytes. |
| No serialization overhead | Raw bytes for terminal data. No base64 or integer arrays. |
| Trivial to implement | 4 message types, ~150 lines of code. |

---

## How Communication Flows

### Two Protocols, Two Purposes

```
+------------------------------------------------------------------+
|                         HOST                                      |
|                                                                   |
|   Elixir OTP                          Cloud Hypervisor            |
|   +----------+    Unix socket    +-------------------+            |
|   |  VM      |<---------------->| cloud-hypervisor  |            |
|   | GenServer|   REST API        | (hypervisor)      |            |
|   +----------+                   +-------------------+            |
|        |                               |                          |
|        | vsock UDS                     | KVM                      |
|        |                               |                          |
|   +----v-----+                   +-----v---------------------+    |
|   | Vsock    |    vsock          |  GUEST VM                 |    |
|   |Connection|<---- CID N ----->|  +---------------------+  |    |
|   +----------+    port 5000     |  | mjolnir-agent       |  |    |
|                                  |  |                     |  |    |
|        Protocol: length-prefix   |  | vsock listener      |  |    |
|        + JSON                    |  | (exec, ping,        |  |    |
|        For: command execution,   |  |  net config,        |  |    |
|        health checks, config     |  |  iroh status)       |  |    |
|                                  |  |                     |  |    |
|                                  |  | Iroh endpoint ------+--+----+--> Internet / Relay
|                                  |  | (QUIC server)       |  |    |
|                                  |  +---------------------+  |    |
|                                  +---------------------------+    |
+------------------------------------------------------------------+
                                                                |
              +-------------+          QUIC/Iroh                |
              |  mjolnir    |<----------------------------------+
              |  (client)   |
              +-------------+
                  Protocol: binary frames
                  For: interactive shell sessions
```

**vsock** (Elixir <-> Guest Agent): synchronous request/response for orchestration commands. Length-prefixed JSON. Used for `exec`, `ping`, `configure_network`, `get_iroh_status`.

**Iroh QUIC** (Client <-> Guest Agent): asynchronous bidirectional streaming for interactive shells. Binary frames. Used for terminal I/O, resize, and exit signaling.

### VM-to-VM Communication

VMs can communicate directly through Iroh, without going through the host:

```
+--------+          Iroh QUIC           +--------+
|  VM A  |<---------------------------->|  VM B  |
| (Iroh  |     (relay or direct)        | (Iroh  |
|endpoint)|                             |endpoint)|
+--------+                              +--------+
  Host 1                                  Host 2
```

Each VM has its own Iroh endpoint with its own Ed25519 identity. VM-A can connect to VM-B using its ticket, regardless of whether they're on the same host, different hosts, or different networks behind NAT.

For same-host VM-to-VM, Iroh still works (localhost relay). We could add iptables FORWARD rules between TAP interfaces for lower latency, but that's premature optimization — Iroh works everywhere.

---

## Future Direction

### Filesystem Checkpointing (Near-term)

BTRFS reflink already enables instant filesystem snapshots:

```elixir
# Snapshot a VM's filesystem
{:ok, snap} = Mjolnir.BTRFS.snapshot("vm-123", "checkpoint-1")

# Clone a VM (instant, shares blocks with original)
{:ok, new_vm} = Mjolnir.VM.clone("vm-123")

# Restore from checkpoint
:ok = Mjolnir.BTRFS.restore("vm-123", "checkpoint-1")
```

This captures workspace state (files, installed packages, project data) without needing memory snapshots. For development environments and AI agent workspaces, this is sufficient.

### Full State Snapshots (same-host freeze/thaw)

Cloud Hypervisor `vm.snapshot` is terminal for virtio-fs: the source
VMM does not resume. Operators therefore get distinct verbs, not a
`--memory` flag on filesystem snapshot. Living spec:
[`vm-freeze`](../openspec/specs/vm-freeze/spec.md).

```
mj freeze <id> <name>   # park RAM+fs; source VM stops
mj thaw <name>          # restore the same VM id
```

Filesystem `POST /api/vms/:id/snapshots` / `mj snapshot create` is
unchanged. Spawn from a memory snapshot is refused. Cross-host restore
(`target_node:`) is still later.

### Cross-Host Migration

BTRFS `send/receive` efficiently transfers filesystem deltas between hosts. Combined with Iroh for transport:

```
Host A                    Iroh QUIC                  Host B
+--------+          encrypted tunnel           +--------+
| BTRFS  |------- send/receive stream -------->| BTRFS  |
| @vms/x |     (only changed blocks)          | @vms/x |
+--------+                                     +--------+
```

### VMs Spawning VMs

A VM can spawn child VMs by calling the Mjolnir API (reachable via TAP networking):

```
VM-A (10.200.0.47)                    Host
      |                                 |
      | curl POST http://host:4000/api/vms
      |------------------------------->|
      |                                | Spawn VM-B
      |                                |
      | {"ticket": "..."}             |
      |<-------------------------------|
      |                                |
      | mjolnir connect <ticket>       |     VM-B
      |--------- Iroh QUIC ------------------>|
      |                                       |
      | Direct VM-to-VM communication         |
```

No special internal API needed. VMs are network citizens with HTTP access to the Mjolnir API.

### Multi-Node Cluster

Elixir distribution connects hosts into a cluster:

```
mjolnir@host1 <------ Erlang distribution ------> mjolnir@host2
     |                                                  |
  VM Registry                                      VM Registry
  (local VMs)                                     (local VMs)
     |                                                  |
  +--+--+--+                                      +--+--+--+
  |VM|VM|VM|                                      |VM|VM|VM|
  +--+--+--+                                      +--+--+--+
```

Erlang distribution handles: cluster membership, VM placement decisions, distributed registry, migration coordination. Iroh handles: VM-to-VM communication, client connections, NAT traversal. Clean separation — BEAM for orchestration, Iroh for data plane.

### AI Agent Execution

The primary use case: run AI agents (Claude Code, etc.) in isolated VMs with full system access:

```elixir
{:ok, vm} = Mjolnir.VM.spawn(%{base_image: "debian-12-ai", memory_mb: 4096})
Mjolnir.VM.exec(vm.id, "pip install anthropic")
Mjolnir.VM.exec(vm.id, "claude-code --api-key $KEY 'Analyze this codebase'")

# Snapshot the agent's workspace after it's done
{:ok, snap} = Mjolnir.BTRFS.snapshot(vm.id, "post-analysis")

# Clone the VM to run a different agent on the same workspace
{:ok, vm2} = Mjolnir.VM.clone(vm.id)
```

Agents get hardware-isolated Linux environments with apt, pip, cargo — everything. BTRFS snapshots let you branch workspaces, checkpoint progress, and restore on failure. Iroh lets agents communicate with each other across any network topology.

### Host sidecars (live)

Guest-facing catalog: [`guide/host-sidecars.md`](guide/host-sidecars.md).
Reserved overlay IP `:host_api_ip` (`10.200.0.1` on `dummy-mjolnir`).
Blob door `:7222` (`blob_door_url`), orchestrator API `:4000`
(`api_url`), tenant Postgres `:5432` (provisioned `DATABASE_URL`),
Redis `:6379` (provisioned `REDIS_URL`, ADR
[`0007`](decisions/0007-host-sidecar-redis.md)).
Typed application logs (pino → RFC 3164 syslog MSG JSON → EventBus
`:app_log`) are ADR
[`0010`](decisions/0010-typed-log.md). Guest `/dev/log` vsock ch2
stays; host ingest is UDP. Living spec lands with implement
changes, not the architecture fold.

Deploy secrets (`mj secrets set|ls|unset`) merge
`/var/lib/mjolnir/deploy/secrets/<slug>.json` at service-VM spawn.
Living spec [`deploy-secrets`](../openspec/specs/deploy-secrets/spec.md)
(`add-deploy-secrets-cli` folded 2026-09-10). Unix `0600 root:root` is
hygiene, not confidentiality — see
[`secrets-architecture.md`](secrets-architecture.md#what-0600-means-steer-2026-09-10).
Not recrypt, not biscuit, not live-guest inject.

Foreign-secret redeem (GitHub PAT, API keys) is ADR
[`0008`](decisions/0008-secret-tokenator.md): opaque vault + salted
Blake3 commitment; holder-bound Biscuit; `POST /api/secrets/redeem`
on existing `api_url`. Living spec
[`secret-tokenator`](../openspec/specs/secret-tokenator/spec.md)
(`add-secret-tokenator` folded 2026-09-10). Code landings are later
(`add-biscuit-runtime`, `add-tokenator-redeem`, `add-capability-mint`,
`add-capability-hop`). Protocol holder/hop/redeem SHALLs live in
identikey-protocol
[`identikey-capability-v1.md` §7](https://github.com/identikey/identikey-protocol/blob/main/docs/standards/identikey-capability-v1.md#7-secret-redemption-profile-foreign-secrets)
(secret-redemption profile; `update-identikey-capability` folded
2026-09-10). Do not copy those SHALLs into `openspec/specs/`.
Living spec [`blob-store`](../openspec/specs/blob-store/spec.md), ADR
[`0003`](decisions/0003-blob-store-mesh.md). Operator runbook
[`runbooks/blob-door.md`](runbooks/blob-door.md). We are not doing
MinIO. iroh-blobs as working-set/transmit is later.

### Channel System (Future)

The local Buzz client fabric (living spec
[`buzz-local-client`](../openspec/specs/buzz-local-client/spec.md), ADR
[`0002`](decisions/0002-buzz-local-client-fabric.md)) takes the first cut:
OTP mailboxes on the host are the body-control queue; Nostr stays the Buzz
event log; admission happens before thaw; the agent nsec is an opaque
SecretStore blob, not a VM-record field. Host Nostr facade
(`Mjolnir.Buzz.Facade`) is the named wake producer; last hop is
conformant Nostr; `identikey-admit` is the portable crate
(`add-buzz-local-runtime` folded 2026-09-10). Channel mobility below
is still later.

Host Postgres as a **declared tenant hotel** (Hypersigil first) is ADR
[`0005`](decisions/0005-host-sidecar-tenant-hotel.md), change
`add-host-sidecar-tenant`. It supersedes ADR 0002 item 7 only. The
control-plane catalog `mjolnir` and the Buzz-log ban stay.

The retry-safe host mailbox (named send as a filesystem spool; 0MQ
patterns composed above it; placement is not the queue) is ADR
[`0006`](decisions/0006-mailbox-as-spool.md), living spec
[`vm-mailbox`](../openspec/specs/vm-mailbox/spec.md). Philosophy:
[`philosophy/mailbox-as-spool.md`](philosophy/mailbox-as-spool.md).

Inspired by pi-calculus, channels will be the universal communication primitive:

```elixir
{:ok, ch} = Mjolnir.Channel.create("results")
:ok = Mjolnir.Channel.subscribe(ch, self())

# VM-A publishes results
Mjolnir.VM.exec(vm_a, "echo result | mjolnir-publish results")

# VM-B receives them
receive do
  {:channel_message, ^ch, data} -> process(data)
end
```

Channels can be passed over channels (channel mobility), enabling dynamic reconfiguration of communication topologies at runtime.

---

## Quick Reference

### Build Commands

```bash
# Elixir orchestration layer
mix deps.get && mix compile
mix test
iex -S mix

# Rust guest agent (cross-compile for VM)
./scripts/build-guest-agent.sh

# Rust client (native build for your machine)
./scripts/build-client.sh

# Full host bootstrap (Linux only, requires root)
sudo USE_LOOPBACK=1 ./scripts/bootstrap-host-ubuntu.sh
```

### Usage

```bash
# Start Mjolnir
iex -S mix

# Spawn a VM
iex> {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "debian-12"})

# Execute a command
iex> {:ok, output} = Mjolnir.VM.exec(vm.id, "uname -a")

# Wait for shell to be ready
iex> {:ok, ticket} = Mjolnir.VM.await_shell(vm.id)

# Connect from any device
$ mjolnir connect '<ticket>'

# Or via the API
$ mjolnir shell <vm-id> --api http://host:4000

# Stop
iex> Mjolnir.VM.stop(vm.id)
```

### Key Paths

```
/var/lib/mjolnir/
  vmlinux                           Firecracker kernel (deprecated, unused)
  vmlinux-ch                        Cloud Hypervisor PVH kernel (active)
  btrfs/
    @base/ubuntu-24.04/             Base rootfs (BTRFS subvolume, directory tree)
    @vms/{uuid}/                    Per-VM rootfs (BTRFS subvolume, CoW clone)
    @snapshots/{name}/              Named filesystem snapshots (BTRFS subvolume clones)
    @snapshots/{name}.mem/          Memory-park artifacts (kind memory)

/tmp/mjolnir/
  {uuid}.sock                       Cloud Hypervisor API socket (Unix domain)
  {uuid}_vsock                      Cloud Hypervisor vsock socket

/etc/mjolnir/
  iroh.key                          Per-VM Iroh identity (32 bytes)
```

### Workspace Layout

```
native/
  Cargo.toml                        Workspace root
  mjolnir_protocol/                 Shared binary frame codec
  mjolnir_guest_agent/              Runs inside VMs
  mjolnir_client/                   CLI for connecting to VMs

lib/mjolnir/
  vm.ex                             VM lifecycle GenServer
  btrfs.ex                          Filesystem operations
  network.ex                        TAP + routing
  event_bus.ex                      Pub/sub for VM lifecycle events
  cleanup.ex                        Orphan process/TAP cleanup on startup
  dormant_registry.ex               ETS registry for dormant VM metadata
  ticket.ex                         z-base-32 ticket encoding
  hypervisor/cloud_hypervisor.ex    CH backend (default, active)
  hypervisor/firecracker.ex         Firecracker backend (deprecated, reference only)
  cloud_hypervisor/client.ex        CH REST client (vm.create, vm.boot, etc.)
  cloud_hypervisor/config.ex        CH vm.create payload builder
  firecracker/client.ex             Firecracker REST client (deprecated)
  firecracker/config.ex             Firecracker VM configuration (deprecated)
  vsock/protocol.ex                 Vsock wire protocol (channel mux)
  vsock/connection.ex               Persistent vsock connection GenServer
  api/router.ex                     HTTP API (health, CRUD, exec, messages, dormant)
  api/auth.ex                       JWT authentication + scope enforcement
```
