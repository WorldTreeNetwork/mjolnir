# Mjolnir Architecture Transition Plan

## Context

### Original Request
Re-order the 5-phase architecture transition to move Cloud Hypervisor earlier (from Phase 4 to Phase 3), map all dependencies, and identify parallel work streams.

### Current State
- Single-node Elixir/OTP app with Firecracker microVMs
- VM lifecycle in `Mjolnir.VM` GenServer (1008 lines), tightly coupled to Firecracker
- 5 duplicated vsock connection blocks in `vm.ex` (configure_guest_network, configure_ssh, configure_identity, try_ping_agent, query_iroh_status) -- all repeat the same CONNECT/send/recv pattern
- Guest agent (Rust/tokio) listens on vsock port 5000, runs Iroh endpoint
- BTRFS ext4 reflink cloning for instant rootfs copies
- Iroh QUIC overlay for NAT-traversing client-to-guest connectivity
- Boot time ~7-10s (Firecracker ~125ms, rest is rootfs clone + network setup + Iroh relay)
- `Mjolnir.Cleanup` module hardcoded to find "firecracker" processes (will need hypervisor awareness)
- `Mjolnir.API.Views` renders VM struct fields (must track struct changes)

### Research Findings (validated)
- Cloud Hypervisor: vsock identical protocol, virtio-fs support, hotplug, live migration, ~200ms boot
- Cloud Hypervisor API is less stable than Firecracker's (breaking changes between minor versions); pin to a specific CH release
- BTRFS send/receive for cross-node replication (btrbk)
- libcluster + Syn for BEAM distribution (gossip for LAN, Postgres for hybrid)
- :pg for pub/sub process groups
- virtiofsd requires starting before the VM, supervising alongside it, and cleaning up on VM stop

---

## Re-ordered Phase Plan

### Phase 1: Persistent Vsock + Make Iroh Optional
### Phase 2: In-VM Agent Protocol
### Phase 3: Cloud Hypervisor Migration (moved up from Phase 4)
### Phase 4: BEAM Distribution + Clustering (moved down from Phase 3)
### Phase 5: Cross-Node Storage Replication

**Rationale for reorder:** Cloud Hypervisor unlocks virtio-fs which fundamentally changes the storage model. Doing this BEFORE clustering means the distributed layer is designed around the better storage model from the start, rather than building clustering around ext4-on-BTRFS and then having to rework it when virtio-fs arrives. The hypervisor abstraction layer also forces the clean separation between VM management and hypervisor specifics that clustering needs.

---

## Dependency Graph

```
Phase 1: Persistent Vsock + Iroh Optional
    |
    v
Phase 2: In-VM Agent Protocol
    |
    +---> Phase 3: Cloud Hypervisor Migration
    |         |
    |         v
    |     Phase 4: BEAM Distribution + Clustering
    |         |
    |         v
    |     Phase 5: Cross-Node Storage Replication
    |
    +---> [PARALLEL] Phase 2 work on guest agent protocol
          can overlap with Phase 3 hypervisor abstraction
```

### Critical Path
```
Phase 1 --> Phase 2 --> Phase 3 --> Phase 4 --> Phase 5
```

### Parallel Work Streams

| Stream A (Elixir Host) | Stream B (Rust Guest) | Stream C (Infrastructure) |
|---|---|---|
| Phase 1: Refactor vsock in vm.ex | -- | -- |
| Phase 1: Make Iroh optional | -- | -- |
| Phase 2: Host-side agent protocol | Phase 2: Guest agent protocol extensions | -- |
| Phase 3: Hypervisor abstraction layer | Phase 3: Guest agent virtio-fs awareness | Phase 3: Cloud Hypervisor spike |
| Phase 4: libcluster + Syn + :pg | -- | Phase 4: Multi-node test infra |
| Phase 5: BTRFS send/receive orchestration | -- | Phase 5: btrbk setup |

**Key parallelism opportunities:**
1. Phase 2 guest agent work and Phase 3 hypervisor spike can overlap (different codebases)
2. Phase 3 Elixir abstraction layer and Phase 3 Cloud Hypervisor client can be built simultaneously
3. Phase 4 clustering logic is independent of Phase 5 storage replication initially

---

## Phase 1: Persistent Vsock + Make Iroh Optional

### Objective
Eliminate the 5 duplicated ephemeral vsock connection blocks in `vm.ex`. Establish a single persistent vsock connection per VM. Make Iroh startup optional so VMs that only need host-to-guest control can boot in <2 seconds.

### Spike Gate: None needed (low risk refactoring)

### Task 1.1: Extract vsock helper into reusable function
**Files:** `lib/mjolnir/vm.ex`
**What:** The functions `configure_guest_network/2`, `configure_ssh/2`, `configure_identity/3`, `try_ping_agent/1`, and `query_iroh_status/1` all repeat the same pattern:
1. `:gen_tcp.connect({:local, vsock_path}, 0, opts, timeout)`
2. Send `"CONNECT 5000\n"`
3. Recv and check for `"OK"`
4. Send length-prefixed JSON
5. Recv 4-byte length + body
6. Parse JSON response
7. Close socket

Extract a `vsock_request(vsock_path, request_map, opts)` function that does steps 1-7.

**Acceptance criteria:**
- All 5 functions use the shared helper
- Zero change in external behavior
- All existing tests pass
- `vm.ex` shrinks by ~150 lines

**Test impact:**
- Existing tests in `test/mjolnir/vm_test.exs` and `test/mjolnir/vm_iroh_test.exs` must continue to pass unchanged
- No new tests needed (pure refactor, same external behavior)

### Task 1.2: Persistent vsock connection per VM

**Design decision -- boot-time vs post-boot vsock:**

The persistent `Vsock.Connection` GenServer is established AFTER the boot sequence completes. The boot sequence (steps 1-5 in `do_boot/1`: `wait_for_boot`, `configure_guest_network`, `configure_ssh`, `configure_identity`, `await_iroh_ready`) continues to use the synchronous `vsock_request/3` helper from Task 1.1. This is deliberate:

- Boot-time calls are sequential, one-shot, and synchronous -- they do not benefit from an async persistent connection
- The persistent connection requires the guest agent to be fully responsive, which is only guaranteed after `wait_for_boot` succeeds
- Mixing boot-time setup with an async GenServer adds complexity (race conditions, partial-boot error handling) for no benefit
- The persistent connection serves post-boot use: `execute_command/2`, `await_shell/2`, and future Phase 2 bidirectional messaging

The persistent connection is started as the LAST step of `do_boot/1`, after all boot-time configuration is complete, right before transitioning to `:running` state.

**Files:** `lib/mjolnir/vsock/connection.ex`, `lib/mjolnir/vm.ex`
**What:** After boot configuration completes, start a `Vsock.Connection` GenServer and keep it alive for the VM's lifetime. Store the connection PID in VM state.
**Dependencies:** Task 1.1 (cleaner to build on de-duplicated code)
**Acceptance criteria:**
- VM struct has `:vsock_conn` field holding persistent connection PID
- `execute_command/2` uses the persistent connection instead of start_link/stop per call
- `await_shell/2` (`handle_call({:await_shell, ...})`) uses the persistent connection instead of raw `:gen_tcp`
- Connection auto-reconnects on failure (supervised, or re-established in handle_info)
- Boot-time configuration commands continue using `vsock_request/3` (NOT the persistent connection)
- All existing tests pass

**Test impact:**
- `test/mjolnir/vm_test.exs` -- existing exec tests validate persistent connection works
- `test/mjolnir/vm_iroh_test.exs` -- existing await_shell tests validate persistent connection path
- New test: verify connection auto-reconnects after transient vsock failure

### Task 1.3: Make Iroh optional

**Design decision -- Iroh-optional mechanism:** Use a vsock protocol message (option a). The host sends a `configure_iroh` message during boot with `{type: "configure_iroh", id: "uuid", enabled: false}`. The guest agent receives this and skips Iroh endpoint startup.

Rationale for protocol message over config file:
- Consistent with existing boot-time configuration pattern (configure_network, configure_ssh, configure_identity all use vsock messages)
- No rootfs modification needed (config file approach requires writing to the ext4 image before boot or after mount, adding complexity)
- The guest agent already processes configuration commands during boot; this is one more
- Allows runtime control: a future "enable Iroh later" message becomes possible

Implementation sequence in `do_boot/1`:
1. (existing) wait_for_boot, configure_guest_network, configure_ssh, configure_identity
2. (new) Send `configure_iroh` message with `{enabled: enable_iroh_option}`
3. (conditional) If `enable_iroh: true` (default), call `await_iroh_ready`; otherwise skip

**Files:** `lib/mjolnir/vm.ex`, `lib/mjolnir/firecracker/config.ex`, `native/mjolnir_guest_agent/src/main.rs`, `lib/mjolnir/vsock/protocol.ex`, `lib/mjolnir/api/views.ex`, config files
**What:** Add `:enable_iroh` option to spawn opts (default: true for backward compat). When false:
- Host sends `configure_iroh` message with `{enabled: false}` during boot
- Guest agent receives this and skips Iroh endpoint startup
- Skip `await_iroh_ready` during boot
- VM is usable via vsock-only (exec, configure commands)
**Dependencies:** Task 1.2 (persistent vsock makes the "vsock-only" mode robust)
**Acceptance criteria:**
- `VM.spawn(%{enable_iroh: false})` boots in <3 seconds (no Iroh relay wait)
- `VM.spawn()` (default) still starts Iroh, backward compatible
- `VM.exec/3` works identically regardless of Iroh setting
- `ticket` and `shell_ready` are nil when Iroh disabled
- Guest agent handles `configure_iroh` message and conditionally starts/skips Iroh
- `render_vm/1` in views.ex includes `enable_iroh` field

**Config changes:**
- Add `enable_iroh: true` default to `config/config.exs`
- Spawn opts `:enable_iroh` overrides config default

**Test impact:**
- New test in `test/mjolnir/vm_test.exs`: spawn with `enable_iroh: false`, verify fast boot and nil ticket
- New test in `test/mjolnir/vm_iroh_test.exs`: verify default spawn still starts Iroh (backward compat)
- New protocol round-trip test for `configure_iroh` message type

### Definition of Done (Phase 1)
- No duplicated vsock connection code in `vm.ex`
- Each VM has exactly one persistent vsock connection (post-boot)
- Boot-time configuration uses shared synchronous helper
- Iroh-disabled VMs boot measurably faster
- All existing tests pass, new tests for optional Iroh

### Commit Strategy
1. `refactor: extract shared vsock request helper in vm.ex`
2. `feat: persistent vsock connection per VM lifecycle`
3. `feat: make Iroh optional with enable_iroh spawn option`

---

## Phase 2: In-VM Agent Protocol

### Objective
Enable VMs to act as agents that can spawn sub-agents, snapshot themselves, and emit events back to the host. Extend the vsock protocol with new message types.

### Spike Gate: None needed (protocol extension, low risk)

### Dependencies
- Phase 1 complete (persistent vsock connection is the transport for all new protocol messages)

### Task 2.1: Define extended protocol message types
**Files:** `lib/mjolnir/vsock/protocol.ex`, `native/mjolnir_guest_agent/src/protocol.rs`
**What:** Add new message types to the wire protocol:

Guest-to-host (agent capabilities):
- `spawn_sub_agent`: `{type: "spawn_sub_agent", id: "uuid", opts: {base_image, memory_mb, ...}}`
- `snapshot_self`: `{type: "snapshot_self", id: "uuid", name: "string"}`
- `emit_event`: `{type: "emit_event", id: "uuid", event: "string", payload: {}}`

Host-to-guest (responses):
- `spawn_sub_agent_response`: `{type: "spawn_sub_agent_response", id: "uuid", vm_id: "string", ticket: "string"}`
- `snapshot_self_response`: `{type: "snapshot_self_response", id: "uuid", ok: bool, metadata: {}}`
- `event_ack`: `{type: "event_ack", id: "uuid"}`

**Acceptance criteria:**
- Protocol module has encoder/decoder for all new types
- Guest agent protocol.rs has matching Rust structs with serde derive
- Round-trip encode/decode test for each message type

**Test impact:**
- New test file: `test/mjolnir/vsock/protocol_test.exs` with round-trip tests for all new message types

### Task 2.2: Host-side agent request handler
**Files:** `lib/mjolnir/vm.ex` (or new `lib/mjolnir/agent_handler.ex`), `lib/mjolnir/vsock/connection.ex`
**What:** The persistent vsock connection receives guest-initiated messages. Route them:
- `spawn_sub_agent` -> calls `VM.spawn/1` with the provided opts, returns new VM's ID and ticket
- `snapshot_self` -> calls `VM.snapshot/3` on the requesting VM
- `emit_event` -> publishes to a local PubSub (preparation for Phase 4's :pg)
**Dependencies:** Task 2.1 (protocol types must exist), Phase 1 Task 1.2 (persistent connection)
**Acceptance criteria:**
- A running VM can trigger sub-agent spawn via vsock message
- A running VM can trigger self-snapshot via vsock message
- Events are published to a local EventBus (GenServer or :pg local)
- Error responses sent back to guest on failure

**Test impact:**
- New integration test: VM sends spawn_sub_agent via vsock, verify new VM created
- New integration test: VM sends snapshot_self via vsock, verify snapshot exists

### Task 2.3: Guest-side agent SDK
**Files:** `native/mjolnir_guest_agent/src/vsock.rs`, new `native/mjolnir_guest_agent/src/agent.rs`
**What:** Expose agent capabilities inside the VM. The guest agent provides a local Unix socket or HTTP endpoint that in-VM processes can call:
- `POST /spawn` -> sends `spawn_sub_agent` over vsock
- `POST /snapshot` -> sends `snapshot_self` over vsock
- `POST /emit` -> sends `emit_event` over vsock
**Dependencies:** Task 2.1, Task 2.2
**Acceptance criteria:**
- In-VM process can `curl localhost:5001/spawn` to create a sub-agent
- In-VM process can `curl localhost:5001/snapshot` to checkpoint itself
- Responses include new VM's connection info

### Task 2.4: Event bus foundation
**Files:** new `lib/mjolnir/event_bus.ex`
**What:** Simple local pub/sub for VM events. Uses `:pg` process groups locally (will extend to distributed in Phase 4).
- Subscribe: `EventBus.subscribe(vm_id)` or `EventBus.subscribe(:all)`
- Publish: `EventBus.publish(vm_id, event_type, payload)`
**Dependencies:** None (can start in parallel with 2.1)
**Acceptance criteria:**
- Local subscribers receive events from VMs
- Events include: `:vm_spawned`, `:vm_stopped`, `:snapshot_created`, `:agent_event`

**Test impact:**
- New test file: `test/mjolnir/event_bus_test.exs` with subscribe/publish tests

### Definition of Done (Phase 2)
- VMs can spawn sub-agents via vsock protocol
- VMs can snapshot themselves
- VMs can emit events consumed by host
- Event bus operational locally
- All new protocol messages have round-trip tests

### Commit Strategy
1. `feat: extend vsock protocol with agent message types`
2. `feat: host-side agent request handler for spawn/snapshot/emit`
3. `feat: guest-side agent SDK with local HTTP endpoint`
4. `feat: local event bus with :pg process groups`

---

## Phase 3: Cloud Hypervisor Migration

### Objective
Add Cloud Hypervisor as an alternative hypervisor backend. Create an abstraction layer so VM lifecycle code is hypervisor-agnostic. Enable virtio-fs for shared filesystem access.

### Spike Gate: MANDATORY before full implementation

#### Spike 3.0: Cloud Hypervisor Feasibility (timeboxed: 2 days)
**Goal:** Prove Cloud Hypervisor can boot the same guest image with vsock working identically.
**Pin to:** Cloud Hypervisor v41.0 (or latest stable at time of spike). Document the exact version.
**Steps:**
1. Install Cloud Hypervisor binary on test host
2. Boot the existing ubuntu-24.04 ext4 image with CH's API
3. Verify vsock `CONNECT 5000\n` protocol works through CH's vsock proxy
4. Verify the existing guest agent responds to ping over CH's vsock
5. Measure boot time (target: <300ms to API ready)
6. Test virtio-fs with virtiofsd sharing a host directory
7. Test virtio-fs with 10 concurrent VMs sharing the same host directory (sanity check, not full perf test)

**Pass criteria (ALL must pass):**
- [ ] Guest agent ping succeeds over CH vsock within 5 seconds of VM start
- [ ] `exec` command returns correct stdout/stderr/exit_code
- [ ] virtio-fs mount visible inside guest at specified mountpoint
- [ ] Boot time to guest-agent-ready is <500ms (excluding Iroh)
- [ ] 10 concurrent VMs with virtio-fs do not deadlock or corrupt

**Fail criteria (any one fails the spike):**
- [ ] vsock protocol incompatibility (different CONNECT handshake)
- [ ] Guest agent binary crashes under CH (different vsock CID handling)
- [ ] virtio-fs requires kernel config changes to guest image
- [ ] Boot time >2x Firecracker with same image

**If spike fails:** Stay on Firecracker, re-evaluate CH in 3 months. Skip Tasks 3.2, 3.3. Still complete Task 3.1 (hypervisor behaviour) to prepare for future migration. Proceed to Phase 4 (clustering) using Firecracker backend. Task 3.4 proceeds with Firecracker-only (the abstraction still has value for testability and future backends).

### Task 3.1: Hypervisor behaviour (interface)
**Files:** new `lib/mjolnir/hypervisor.ex` (behaviour), `lib/mjolnir/hypervisor/firecracker.ex`, `lib/mjolnir/cleanup.ex`, config files
**Dependencies:** Spike 3.0 passes (or fails -- this task proceeds either way)
**What:** Define an Elixir behaviour that abstracts hypervisor operations:

```elixir
@callback start_vm(config :: map()) :: {:ok, pid :: port()} | {:error, term()}
@callback configure_vm(socket_path :: String.t(), config :: map()) :: :ok | {:error, term()}
@callback start_instance(socket_path :: String.t()) :: :ok | {:error, term()}
@callback pause_instance(socket_path :: String.t()) :: :ok | {:error, term()}
@callback resume_instance(socket_path :: String.t()) :: :ok | {:error, term()}
@callback stop_instance(socket_path :: String.t()) :: :ok | {:error, term()}
@callback cleanup(state :: map()) :: :ok
@callback vsock_path(socket_dir :: String.t(), vm_id :: String.t()) :: String.t()
@callback process_name() :: String.t()  # For cleanup: "firecracker", "cloud-hypervisor", etc.
```

Move existing Firecracker logic from `vm.ex` and `firecracker/client.ex` into `hypervisor/firecracker.ex`.

Update `Mjolnir.Cleanup` to use `process_name/0` callback instead of hardcoded "firecracker" string (line 38 of cleanup.ex).

**Acceptance criteria:**
- `Mjolnir.Hypervisor` behaviour defined with all callbacks
- `Mjolnir.Hypervisor.Firecracker` implements it using existing code
- `vm.ex` calls behaviour functions instead of directly calling `Firecracker.Client`
- `Mjolnir.Cleanup.sweep/0` uses configured hypervisor's `process_name/0` to find orphans
- All existing tests pass with Firecracker backend
- Hypervisor selection via config: `config :mjolnir, :hypervisor, Mjolnir.Hypervisor.Firecracker`

**Config changes:**
- Add `hypervisor: Mjolnir.Hypervisor.Firecracker` default to `config/config.exs`

**Test impact:**
- Existing tests in `test/mjolnir/vm_test.exs` must pass unchanged (Firecracker backend)
- New test: verify `Mjolnir.Hypervisor.Firecracker` implements all behaviour callbacks

### Task 3.2: Cloud Hypervisor client
**Files:** new `lib/mjolnir/hypervisor/cloud_hypervisor.ex`, new `lib/mjolnir/cloud_hypervisor/client.ex`, new `lib/mjolnir/cloud_hypervisor/config.ex`
**Dependencies:** Task 3.1 (behaviour to implement), Spike 3.0 passes (API knowledge)
**What:** Implement the `Mjolnir.Hypervisor` behaviour for Cloud Hypervisor:
- REST API client (Unix socket, similar to Firecracker but different endpoints)
- Config struct mapping Mjolnir config to CH API payloads
- VM lifecycle: create -> boot -> pause -> resume -> stop
- vsock configuration (same guest CID, CH manages the proxy UDS differently)
- `process_name/0` returns `"cloud-hypervisor"` for cleanup

**API stability risk mitigation:** Pin to a specific CH version in documentation and CI. Wrap CH-specific API structs so version changes are isolated to the client module.

**Acceptance criteria:**
- Can boot a VM with Cloud Hypervisor using existing guest image
- vsock communication works (ping, exec)
- Network (TAP) works identically
- Snapshot (pause + reflink) works

**Test impact:**
- New test file: `test/mjolnir/hypervisor/cloud_hypervisor_test.exs`
- Tests mirror existing vm_test.exs but with CH backend (behind a tag for CI environments without CH)

### Task 3.3: virtio-fs integration
**Files:** `lib/mjolnir/hypervisor/cloud_hypervisor.ex`, new `lib/mjolnir/virtiofs.ex`
**Dependencies:** Task 3.2 (CH must be working)
**What:** Add virtio-fs support alongside virtio-blk:

**virtiofsd process management:**
- `Mjolnir.VirtioFS` module manages virtiofsd lifecycle
- virtiofsd must be started BEFORE the VM boots (it creates the vhost-user socket that CH connects to)
- virtiofsd is started as an OS Port (same pattern as Firecracker process management -- crash isolation)
- One virtiofsd process per shared directory per VM
- virtiofsd PID stored in VM state for cleanup
- On VM stop: kill virtiofsd after VM process (reverse of start order)
- On virtiofsd crash: log warning, VM continues running (shared dir unavailable but VM is not broken)

Implementation:
- Start virtiofsd process for shared directory
- Configure CH to expose virtio-fs device pointing at virtiofsd socket
- Guest mounts shared directory (via guest agent `configure_virtiofs` message or fstab)
- Support both modes: ext4-on-btrfs (existing) and virtio-fs (new)

**Acceptance criteria:**
- Host directory visible inside guest at `/mnt/shared` (or configured path)
- Files written in guest appear on host immediately (no sync delay)
- Can run alongside existing ext4 rootfs (hybrid mode)
- virtiofsd process cleaned up on VM stop
- virtiofsd crash does not crash the VM
- 10 concurrent VMs sharing the same host directory works without corruption

**Test impact:**
- New test: virtio-fs mount visible, file round-trip works
- New test: virtiofsd cleanup on VM stop (no orphaned processes)

### Task 3.4: Refactor VM.ex to use hypervisor abstraction
**Files:** `lib/mjolnir/vm.ex`, `lib/mjolnir/api/views.ex`
**Dependencies:** Task 3.1 (behaviour definition), Task 3.2 (CH client -- need both backends to validate the abstraction is correct)
**What:** Replace all direct Firecracker references in `vm.ex` with hypervisor behaviour calls:
- `do_boot/1`: use `Hypervisor.start_vm/1` and `Hypervisor.configure_vm/2`
- `do_snapshot/3`: use `Hypervisor.pause_instance/1` and `Hypervisor.resume_instance/1`
- `cleanup/1`: use `Hypervisor.cleanup/1`
- Store hypervisor module in VM state for runtime dispatch

Also update `lib/mjolnir/api/views.ex`:
- `render_vm/1` includes `:hypervisor` field showing which backend is in use
- `render_config/1` includes any hypervisor-specific config (e.g., virtio-fs mounts)

**Acceptance criteria:**
- `vm.ex` has zero direct references to `Firecracker.Client`
- Can switch hypervisor via config without code changes
- Both Firecracker and Cloud Hypervisor pass the same test suite
- VM struct includes `:hypervisor` field

**Test impact:**
- All existing tests in `test/mjolnir/vm_test.exs` pass with Firecracker
- Same test suite passes with CH backend (tagged for environments with CH installed)
- New test in `test/mjolnir/api/router_test.exs`: API response includes `hypervisor` field

### Definition of Done (Phase 3)
- Hypervisor abstraction layer in place
- Cloud Hypervisor boots VMs with full vsock + networking
- virtio-fs working for shared host directories
- Can switch between Firecracker and CH via config
- All tests pass on both backends
- Cleanup module works with both hypervisors

### Commit Strategy
1. `spike: Cloud Hypervisor feasibility validation`
2. `refactor: extract Hypervisor behaviour from Firecracker-specific code`
3. `feat: Cloud Hypervisor client implementing Hypervisor behaviour`
4. `feat: virtio-fs integration for Cloud Hypervisor backend`
5. `refactor: vm.ex uses hypervisor abstraction, zero Firecracker imports`

---

## Phase 4: BEAM Distribution + Clustering

### Objective
Enable multi-node Mjolnir clusters where VMs can be spawned on any node and discovered/communicated with from any node.

### Spike Gate: MANDATORY

#### Spike 4.0: BEAM Distribution Latency (timeboxed: 1 day)
**Goal:** Validate that BEAM distribution meets control-plane latency requirements on target hardware.
**Steps:**
1. Set up 2-node Elixir cluster with libcluster gossip strategy
2. Measure GenServer.call latency cross-node (P50, P99)
3. Test Syn registry convergence time after node join
4. Test :pg group membership propagation

**Pass criteria:**
- [ ] GenServer.call P99 < 10ms on LAN
- [ ] Syn registry converges within 2 seconds of node join
- [ ] :pg group updates propagate within 1 second

**Fail criteria:**
- [ ] P99 > 50ms (too slow for control plane)
- [ ] Syn conflicts on concurrent VM spawns from different nodes

### Dependencies
- Phase 1 complete (persistent vsock, the communication primitive)
- Phase 2 complete (event bus, which will be distributed)
- Phase 3 Task 3.1 complete (hypervisor abstraction, so nodes can run different hypervisors)

### Task 4.1: libcluster integration
**Files:** `lib/mjolnir/application.ex`, `mix.exs`, new `lib/mjolnir/cluster.ex`, config files
**What:** Add libcluster with gossip strategy (LAN) and Postgres strategy (hybrid).
**Acceptance criteria:**
- Nodes auto-discover on LAN via multicast gossip
- `Node.list()` shows connected peers within 5 seconds of startup
- Config-driven strategy selection

**Test impact:**
- New test file: `test/mjolnir/cluster_test.exs` (unit tests for config parsing, strategy selection)

### Task 4.2: Distributed VM registry with Syn

**Design decision -- Registry.select migration:**

`VM.list/0` currently uses `Registry.select/2` (line 170 of vm.ex) which has no direct Syn equivalent. Syn provides `Syn.members/2` to list all registered processes in a scope/group, but does not support match specs.

Migration strategy:
- Register VMs in a Syn scope (e.g., `:vms`) with the vm_id as the key
- Store minimal metadata as Syn metadata: `%{node: node(), hypervisor: module}`
- `VM.list/0` becomes `Syn.lookup(:vms) |> Enum.map(...)` -- Syn returns all registered processes cluster-wide
- All 8 `Registry.lookup/2` calls (lines 104, 122, 141, 170, 193, 216, 240, 272) become `Syn.lookup(:vms, vm_id)`
- The `via_tuple/1` at line 443 becomes `{:via, Syn, {:vms, vm_id}}`

Key difference: `Registry.select` returns `{vm_id, pid}` tuples with a match spec; `Syn.members/2` returns `{pid, metadata}` tuples. The `VM.list/0` function will need to iterate `Syn.members(:vms)` and call `GenServer.call(pid, :get_state)` on each (same pattern as current, just different enumeration).

**Files:** `lib/mjolnir/application.ex`, `lib/mjolnir/vm.ex`, new `lib/mjolnir/vm_registry.ex`
**What:** Replace local `Registry` with Syn for distributed process registry:
- VM processes registered globally by UUID via Syn
- `VM.get(vm_id)` works from any node (transparent GenServer.call routing)
- `VM.list()` returns VMs from all nodes via `Syn.members/2`
**Dependencies:** Task 4.1
**Acceptance criteria:**
- VM spawned on node A is callable from node B via `VM.exec(vm_id, cmd)`
- `VM.list()` aggregates VMs from all connected nodes
- VM process death on one node is detected by other nodes within 5 seconds
- No UUID conflicts (UUIDs are globally unique by construction)

**Test impact:**
- Update existing `test/mjolnir/vm_test.exs` to work with Syn registry
- New test: multi-node VM list aggregation (may require test infrastructure for multi-node)

### Task 4.3: Distributed event bus
**Files:** `lib/mjolnir/event_bus.ex`
**What:** Extend the Phase 2 event bus to use `:pg` across the cluster:
- Events published on one node received by subscribers on all nodes
- Subscriber can filter by VM ID, event type, or source node
**Dependencies:** Task 4.1, Phase 2 Task 2.4
**Acceptance criteria:**
- Event emitted on node A received by subscriber on node B
- Subscriber on node B gets events for VMs on both nodes
- Event delivery is best-effort (no persistence, appropriate for control plane)

**Test impact:**
- Extend `test/mjolnir/event_bus_test.exs` with distributed delivery tests

### Task 4.4: Cluster-aware API
**Files:** `lib/mjolnir/api/router.ex`, `lib/mjolnir/api/views.ex`
**What:** API routes to any node, operations transparently forwarded:
- `POST /api/vms` can specify target node or use scheduler
- `GET /api/vms` returns cluster-wide VM list
- `POST /api/vms/:id/exec` routes to the node owning the VM
**Dependencies:** Task 4.2
**Acceptance criteria:**
- Single API endpoint serves the entire cluster
- VM operations work regardless of which node receives the request
- API response includes `node` field showing where VM is running

**Views changes:**
- `render_vm/1` and `render_vm_summary/1` include `:node` field

**Test impact:**
- Update `test/mjolnir/api/router_test.exs` with cluster-aware API tests

### Task 4.5: Simple scheduler
**Files:** new `lib/mjolnir/scheduler.ex`
**What:** Decide which node to place a new VM on:
- Round-robin as default
- Respect resource constraints (memory, CPU capacity per node)
- Configurable strategy
**Dependencies:** Task 4.1, Task 4.2
**Acceptance criteria:**
- VMs distributed across nodes when no preference specified
- Can pin VM to specific node via spawn opts
- Scheduler reports available capacity per node

**Test impact:**
- New test file: `test/mjolnir/scheduler_test.exs`

### Definition of Done (Phase 4)
- Multi-node cluster auto-discovers and connects
- VMs discoverable and operable from any node
- Events propagate across cluster
- API serves cluster-wide operations
- Simple scheduling distributes VMs

### Commit Strategy
1. `feat: libcluster integration with gossip and Postgres strategies`
2. `feat: distributed VM registry with Syn replacing local Registry`
3. `feat: distributed event bus over :pg process groups`
4. `feat: cluster-aware API with transparent request routing`
5. `feat: simple round-robin VM scheduler`

---

## Phase 5: Cross-Node Storage Replication

### Objective
Enable VM snapshots to be available on multiple nodes for fast restore anywhere in the cluster. Use BTRFS send/receive for efficient incremental replication.

### Spike Gate: MANDATORY

#### Spike 5.0: BTRFS Send/Receive Performance (timeboxed: 1 day)
**Goal:** Measure BTRFS send/receive throughput and latency for typical VM images.
**Steps:**
1. Create a 2GB ext4 rootfs with typical Ubuntu install
2. Measure initial full send/receive between two BTRFS volumes
3. Boot VM, install packages, measure incremental send/receive
4. Test btrbk automated replication

**Pass criteria:**
- [ ] Incremental send for 100MB of changes completes in <5 seconds on LAN
- [ ] btrbk can manage automated replication with <1 minute lag
- [ ] Receiving node can boot VM from replicated snapshot

**Fail criteria:**
- [ ] Full send for 2GB image takes >30 seconds on 10Gbps LAN
- [ ] Incremental sends are not significantly smaller than full sends

### Dependencies
- Phase 3 complete (storage model may include virtio-fs, replication strategy must account for both)
- Phase 4 Task 4.1 complete (cluster connectivity needed for cross-node operations)

### Task 5.1: BTRFS send/receive orchestration
**Files:** `lib/mjolnir/btrfs.ex`, new `lib/mjolnir/storage/replication.ex`
**What:** Orchestrate BTRFS send/receive operations:
- `Replication.send_snapshot(name, target_node)` - send snapshot to specific node
- `Replication.replicate_snapshot(name)` - send to all nodes (or N replicas)
- Use BTRFS send piped over SSH or a custom BEAM-based transfer
**Acceptance criteria:**
- Snapshot on node A can be sent to node B
- Incremental sends work (parent snapshot tracking)
- Transfer progress reported via event bus

### Task 5.2: Snapshot catalog
**Files:** new `lib/mjolnir/storage/catalog.ex`
**What:** Distributed catalog tracking which snapshots exist on which nodes:
- Uses Syn or :pg for cluster-wide state
- Tracks: snapshot name, source node, replica nodes, size, creation time
- Answers: "where can I get snapshot X?" queries
**Dependencies:** Task 5.1, Phase 4 Task 4.1
**Acceptance criteria:**
- Catalog reflects snapshot availability across all nodes
- `Catalog.find_snapshot(name)` returns list of nodes that have it
- Catalog updates propagate within 5 seconds

### Task 5.3: Snapshot-aware VM spawning
**Files:** `lib/mjolnir/vm.ex`, `lib/mjolnir/scheduler.ex`
**What:** When spawning from a snapshot, prefer nodes that already have it:
- Scheduler checks catalog for snapshot locality
- If snapshot not local, trigger on-demand replication before boot
- Or spawn on a node that has it (locality-aware scheduling)
**Dependencies:** Task 5.2, Phase 4 Task 4.5
**Acceptance criteria:**
- `VM.spawn(%{snapshot: "my-env"})` prefers nodes with the snapshot
- If no node has it locally, replication happens transparently
- Spawn-from-snapshot on local node is still instant (reflink)

### Task 5.4: btrbk integration for automated replication
**Files:** new `lib/mjolnir/storage/btrbk.ex`, config files
**What:** Use btrbk for continuous background replication:
- Configure btrbk to replicate `@snapshots/` to peer nodes
- Mjolnir manages btrbk config generation based on cluster topology
- Retention policies configurable
**Dependencies:** Task 5.1
**Acceptance criteria:**
- New snapshots automatically replicated to configured number of replicas
- Old snapshots cleaned up per retention policy
- btrbk status visible via API

### Definition of Done (Phase 5)
- Snapshots replicated across nodes
- Catalog tracks snapshot locations
- Scheduler uses snapshot locality for placement
- Automated replication via btrbk
- Snapshot restore works from any replica node

### Commit Strategy
1. `feat: BTRFS send/receive orchestration for cross-node snapshot transfer`
2. `feat: distributed snapshot catalog with cluster-wide availability tracking`
3. `feat: snapshot-locality-aware VM scheduling`
4. `feat: btrbk integration for automated background replication`

---

## Full Dependency Map

```
Task 1.1 (vsock helper)
  └─> Task 1.2 (persistent vsock)
        ├─> Task 1.3 (Iroh optional)
        └─> Task 2.1 (protocol types)
              ├─> Task 2.2 (host agent handler)
              │     └─> Task 2.3 (guest agent SDK)
              └─> [parallel] Task 2.4 (event bus)

        Spike 3.0 (CH feasibility) ─── pass/fail gate
          │
          ├─ PASS ─> Task 3.1 (hypervisor behaviour)
          │            ├─> Task 3.2 (CH client)
          │            │     ├─> Task 3.3 (virtio-fs)
          │            │     └─> Task 3.4 (vm.ex refactor) [needs 3.1 AND 3.2]
          │            └─────────> Task 3.4 (vm.ex refactor)
          │
          └─ FAIL ─> Task 3.1 (hypervisor behaviour, Firecracker-only)
                       └─> Task 3.4 (vm.ex refactor, single backend)
                             └─> Phase 4 (proceed without CH)

        Spike 4.0 (BEAM latency) ─── pass/fail gate
          │
          └─> Task 4.1 (libcluster)
                ├─> Task 4.2 (Syn registry)
                │     └─> Task 4.4 (cluster API)
                ├─> Task 4.3 (distributed events)
                └─> Task 4.5 (scheduler)

        Spike 5.0 (BTRFS send/recv) ─── pass/fail gate
          │
          └─> Task 5.1 (send/receive)
                ├─> Task 5.2 (catalog)
                │     └─> Task 5.3 (snapshot-aware spawn)
                └─> Task 5.4 (btrbk)
```

### Cross-Phase Dependencies (what actually blocks what)

| Task | Hard Dependencies | Soft Dependencies |
|---|---|---|
| Spike 3.0 | None (can start anytime) | Easier after Phase 1 (vsock understanding) |
| Task 3.1 | Spike 3.0 pass OR fail (proceed either way) | Phase 2 complete (cleaner interface) |
| Task 3.2 | Task 3.1, Spike 3.0 PASS | -- |
| Task 3.4 | Task 3.1 AND Task 3.2 (need both backends to validate abstraction) | -- |
| Spike 4.0 | None (can start anytime) | -- |
| Task 4.2 | Task 4.1, Phase 1 complete | Phase 3 Task 3.4 (hypervisor-agnostic VM) |
| Task 4.3 | Task 4.1, Phase 2 Task 2.4 | -- |
| Task 5.1 | Phase 4 Task 4.1 | Phase 3 complete (storage model settled) |
| Task 5.3 | Task 5.2, Phase 4 Task 4.5 | -- |

**Note:** Task 2.1 (protocol types) and Task 3.1 (hypervisor behaviour) are independent -- protocol messages and hypervisor abstraction operate at different layers. They can proceed in parallel.

### What Can Start Early (Parallel)

These items have no hard dependencies on prior phases and can be timeboxed as early investigations:

1. **Spike 3.0** (Cloud Hypervisor feasibility) -- can start immediately, even before Phase 1
2. **Spike 4.0** (BEAM distribution latency) -- can start immediately
3. **Task 2.4** (Event bus foundation) -- only depends on `:pg` understanding, not Phase 1
4. **Spike 5.0** (BTRFS send/receive performance) -- can start immediately

---

## Success Criteria (Overall)

| Metric | Target | Phase |
|---|---|---|
| VM boot time (vsock-only, no Iroh) | <2 seconds | Phase 1 |
| VM boot time (with Iroh) | <5 seconds | Phase 1 |
| Sub-agent spawn from within VM | <3 seconds | Phase 2 |
| Self-snapshot from within VM | <2 seconds | Phase 2 |
| Hypervisor switch without code change | Config only | Phase 3 |
| virtio-fs file visibility latency | <100ms | Phase 3 |
| Cross-node GenServer.call P99 | <10ms | Phase 4 |
| Cluster VM discovery after node join | <5 seconds | Phase 4 |
| Incremental snapshot replication (100MB delta) | <5 seconds | Phase 5 |
| Snapshot-local VM spawn | <2 seconds | Phase 5 |

---

## Files Impact Summary

### Phase 1
- `lib/mjolnir/vm.ex` -- major refactor (vsock dedup, persistent conn, Iroh optional)
- `lib/mjolnir/vsock/connection.ex` -- enhance for persistent lifecycle
- `lib/mjolnir/vsock/protocol.ex` -- add `configure_iroh` message type
- `lib/mjolnir/firecracker/config.ex` -- add enable_iroh field
- `lib/mjolnir/api/views.ex` -- add enable_iroh to rendered VM
- `config/config.exs` -- add `enable_iroh: true` default
- `native/mjolnir_guest_agent/src/main.rs` -- conditional Iroh startup via protocol message
- `test/mjolnir/vm_test.exs` -- new tests for enable_iroh: false
- `test/mjolnir/vm_iroh_test.exs` -- backward compat tests

### Phase 2
- `lib/mjolnir/vsock/protocol.ex` -- new message types
- `lib/mjolnir/vsock/connection.ex` -- handle guest-initiated messages
- `lib/mjolnir/vm.ex` -- route agent requests
- `native/mjolnir_guest_agent/src/protocol.rs` -- new message types
- `native/mjolnir_guest_agent/src/vsock.rs` -- handle new messages
- NEW: `lib/mjolnir/event_bus.ex`
- NEW: `native/mjolnir_guest_agent/src/agent.rs`
- NEW: `test/mjolnir/vsock/protocol_test.exs`
- NEW: `test/mjolnir/event_bus_test.exs`

### Phase 3
- NEW: `lib/mjolnir/hypervisor.ex` (behaviour)
- NEW: `lib/mjolnir/hypervisor/firecracker.ex` (extracted from existing)
- NEW: `lib/mjolnir/hypervisor/cloud_hypervisor.ex`
- NEW: `lib/mjolnir/cloud_hypervisor/client.ex`
- NEW: `lib/mjolnir/cloud_hypervisor/config.ex`
- NEW: `lib/mjolnir/virtiofs.ex`
- `lib/mjolnir/vm.ex` -- use hypervisor abstraction
- `lib/mjolnir/firecracker/client.ex` -- moved behind behaviour
- `lib/mjolnir/cleanup.ex` -- use hypervisor `process_name/0` instead of hardcoded "firecracker"
- `lib/mjolnir/api/views.ex` -- add hypervisor field to rendered VM
- `config/config.exs` -- add `hypervisor: Mjolnir.Hypervisor.Firecracker` default
- NEW: `test/mjolnir/hypervisor/cloud_hypervisor_test.exs`
- `test/mjolnir/api/router_test.exs` -- verify hypervisor field in API response

### Phase 4
- `lib/mjolnir/application.ex` -- add libcluster, Syn
- `lib/mjolnir/vm.ex` -- Syn registry instead of local Registry (via_tuple, all lookup calls, list)
- `lib/mjolnir/api/router.ex` -- cluster-aware routing
- `lib/mjolnir/api/views.ex` -- add node field to rendered VM
- `lib/mjolnir/event_bus.ex` -- distributed :pg
- NEW: `lib/mjolnir/cluster.ex`
- NEW: `lib/mjolnir/vm_registry.ex`
- NEW: `lib/mjolnir/scheduler.ex`
- `mix.exs` -- add libcluster, syn deps
- `test/mjolnir/vm_test.exs` -- update for Syn registry
- NEW: `test/mjolnir/cluster_test.exs`
- NEW: `test/mjolnir/scheduler_test.exs`
- `test/mjolnir/api/router_test.exs` -- cluster-aware API tests

### Phase 5
- `lib/mjolnir/btrfs.ex` -- send/receive operations
- `lib/mjolnir/vm.ex` -- snapshot-aware spawning
- `lib/mjolnir/scheduler.ex` -- locality awareness
- NEW: `lib/mjolnir/storage/replication.ex`
- NEW: `lib/mjolnir/storage/catalog.ex`
- NEW: `lib/mjolnir/storage/btrbk.ex`
