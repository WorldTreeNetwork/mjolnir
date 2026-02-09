# Specification: NAT-Traversing Shell Access for Firecracker VMs

**Task ID:** iroh-shell
**Created:** 2026-01-28
**Status:** Ready for Implementation
**Version:** 1.1
**Plan:** [plan.md](./plan.md)

---

## 1. Problem Statement

### The Problem
Firecracker microVMs in Mjolnir are currently unreachable black boxes. They have:
- No network interface (can't reach the internet)
- No shell access (only non-interactive `exec` via vsock)
- No way to connect from outside the host
- No VM↔VM communication

Users cannot SSH into their VMs, cannot run interactive sessions (like Claude Code), and cannot expose services.

### Current Situation
- VMs communicate with host only via vsock (control plane)
- Guest agent supports `exec` (non-interactive command execution)
- Serial console available but impractical for remote access
- No NAT traversal — VMs behind routers are completely isolated

### Desired Outcome
- **Spawn a VM anywhere** (home router, cloud, mobile hotspot)
- **Shell in from anywhere** (no port forwarding, no VPN setup)
- **VMs can reach each other** (cross-host, cross-NAT)
- **Full egress** (apt install, Claude Code sessions, curl)
- **Service publishing** (expose ports to other Iroh nodes)

---

## 2. User Personas

### Primary User: Developer
- **Who:** Developer using Mjolnir to run isolated workspaces
- **Goals:** Shell into VM, run commands, checkpoint state, restore later
- **Pain points:** Can't access VM remotely, can't work from mobile/travel

### Secondary User: AI Agent (Claude Code)
- **Who:** Automated AI assistant running inside or connecting to VMs
- **Goals:** Execute commands, read/write files, run interactive sessions
- **Pain points:** No interactive terminal, no persistent sessions

### Tertiary User: Automated System
- **Who:** CI/CD, orchestration systems, other Mjolnir nodes
- **Goals:** Programmatic access to VMs, service discovery, VM↔VM RPC
- **Pain points:** No API for remote access, no service advertisement

---

## 3. Functional Requirements

### FR-1: Guest Outbound Networking
**Description:** VMs can reach the internet (egress only initially)

**User Story:**
> As a developer, I want my VM to have internet access so that I can run `apt install`, `curl`, and Claude Code sessions.

**Acceptance Criteria:**
- [ ] Given a running VM, when I run `curl https://example.com`, then I get a response
- [ ] Given a running VM, when I run `apt update && apt install git`, then packages install successfully
- [ ] Given a VM behind a NAT'd host, when I run `curl`, then it works (host provides NAT)

**Priority:** Must Have (Phase 1)

**Technical Notes:**
- TAP interface per VM
- Host provides NAT via iptables MASQUERADE
- Guest configured with static IP + default route via TAP

---

### FR-2: Interactive PTY Shell via Iroh
**Description:** Users can connect to a VM shell from anywhere using Iroh's NAT traversal

**User Story:**
> As a developer, I want to shell into my VM from my laptop over Starlink without configuring port forwarding.

**Acceptance Criteria:**
- [ ] Given a running VM, when I connect using the VM's Iroh ticket, then I get an interactive shell
- [ ] Given the host is behind NAT, when I connect from outside the NAT, then it works (hole punching)
- [ ] Given hole punching fails, when I connect, then it falls back to relay and still works
- [ ] Given I'm in a shell, when I run `vim` or `htop`, then interactive TUI apps work correctly

**Priority:** Must Have (Phase 2)

**Technical Notes:**
- Guest agent embeds iroh-net
- PTY allocated per connection
- Ticket sent to host via vsock on boot
- Client uses ticket to connect (no DHT required)

---

### FR-3: Shell Readiness Notification
**Description:** Host knows when VM shell is ready and can provide connection info to clients

**User Story:**
> As a developer, I want to know when my VM is ready for shell access so that I don't have to poll or guess.

**Acceptance Criteria:**
- [ ] Given a VM is spawning, when the Iroh endpoint registers with relay, then host receives readiness notification via vsock
- [ ] Given readiness notification received, when client requests shell, then host provides ticket immediately
- [ ] Given a VM with pre-generated keypair, when spawned, then Node ID is known before boot completes

**Priority:** Must Have (Phase 2)

---

### FR-4: Multiple Concurrent Sessions
**Description:** Multiple users/agents can connect to the same VM simultaneously

**User Story:**
> As a developer, I want to have multiple terminal sessions open to the same VM so that I can work in parallel.

**Acceptance Criteria:**
- [ ] Given a VM with one active shell session, when another client connects, then both sessions work independently
- [ ] Given two sessions, when one runs a command, then the other is not affected
- [ ] Given a session disconnects, when other sessions are active, then they continue working

**Priority:** Should Have (Phase 2/3)

---

### FR-5: File Transfer
**Description:** Users can transfer files to/from VMs

**User Story:**
> As a developer, I want to copy files to and from my VM so that I can work with local data.

**Acceptance Criteria:**
- [ ] Given a running VM, when I use the transfer command, then files copy successfully
- [ ] Given a large file (100MB), when I transfer it, then it completes in reasonable time
- [ ] Given a transfer is interrupted, when I retry, then it can resume (nice to have)

**Priority:** Should Have (Phase 3)

**Technical Notes:**
- Could use Iroh blobs (content-addressed, resumable)
- Or simple file streaming over QUIC
- Alternative: direct BTRFS snapshot transfer for whole-workspace sync

---

### FR-6: VM↔VM Connectivity
**Description:** Any VM can connect to any other VM, regardless of host location

**User Story:**
> As a developer, I want VM-A to connect to a service running on VM-B, even if they're on different hosts behind different NATs.

**Acceptance Criteria:**
- [ ] Given VM-A on Host-1 and VM-B on Host-2 (both behind NAT), when VM-A connects to VM-B's Iroh address, then connection succeeds
- [ ] Given VM-B is publishing a service, when VM-A looks up the service, then it can discover and connect
- [ ] Given VMs are on the same host, when they connect, then latency is minimal (ideally direct, not via relay)

**Priority:** Must Have (Phase 4)

---

### FR-7: Service Advertisement
**Description:** VMs can publish services that other nodes can discover and connect to

**User Story:**
> As a developer, I want to expose port 8080 from my VM so that other VMs or external clients can connect to my web server.

**Acceptance Criteria:**
- [ ] Given a VM running a service on port 8080, when I publish it via Iroh, then other nodes can discover it
- [ ] Given a published service, when a client connects using the service address, then traffic routes to the correct port
- [ ] Given the service stops, when the VM unpublishes it, then discovery stops returning it

**Priority:** Must Have (Phase 4)

**Technical Notes:**
- Iroh doesn't have built-in port publishing, but we can build it:
  - Service = (node_id, port, metadata)
  - Published to DHT or announced via custom protocol
  - Client connects to node_id, requests port forwarding

---

### FR-8: Host Networking Setup Automation
**Description:** Networking setup is automated and well-documented

**User Story:**
> As a Mjolnir operator, I want networking to be set up automatically so that I don't have to manually configure iptables.

**Acceptance Criteria:**
- [ ] Given a fresh host, when I run bootstrap-host.sh, then networking prerequisites are configured
- [ ] Given a VM spawns, when TAP is created, then it's automatically configured with correct IP/routes
- [ ] Given something goes wrong, when I debug, then there's clear documentation on how to troubleshoot
- [ ] Given a VM terminates, when cleanup runs, then TAP interface is removed

**Priority:** Must Have (Phase 1)

---

## 4. Non-Functional Requirements

### Performance
- **Shell latency:** < 100ms round-trip for keystrokes (p95)
- **Connection establishment:** < 2 seconds from ticket to shell prompt
- **Boot to shell-ready:** < 500ms after kernel boot

### Security
- **Encryption:** All traffic encrypted via QUIC/TLS (Iroh default)
- **Authentication:** Connections require valid ticket or node ID
- **Isolation:** VMs cannot access host network except via designated NAT

### Reliability
- **Relay fallback:** If hole punching fails (10% of cases), relay must work
- **Reconnection:** Client should auto-reconnect on network change
- **No single point of failure:** n0's public relays + option to self-host

### Scalability
- **VMs per host:** Support 50+ VMs with networking
- **Concurrent sessions:** 10+ per VM
- **Relay bandwidth:** Consider self-hosted relay for high-traffic deployments

---

## 5. Out of Scope (This Milestone)

- ❌ **SSH protocol compatibility** — Custom Iroh-based shell is fine; SSH can come later
- ❌ **Self-hosted relay infrastructure** — Use n0's public relays initially
- ❌ **IPv6 in guest** — IPv4 sufficient for now
- ❌ **DNS names for VMs** — Node IDs + tickets for now; DNS integration later
- ❌ **Bandwidth throttling/QoS** — All traffic equal priority for now
- ❌ **Windows/macOS guest support** — Linux only

---

## 6. Edge Cases & Error Handling

| Scenario | Expected Behavior |
|----------|-------------------|
| VM boots but Iroh relay unreachable | Retry with backoff; report error via vsock after timeout |
| Client connects during VM shutdown | Graceful connection close with error message |
| TAP interface creation fails | VM spawn fails with clear error; no zombie processes |
| Host loses internet mid-session | Session freezes; auto-reconnects when network returns |
| Two VMs get same TAP IP (bug) | Validation prevents this; clear error if detected |
| Guest agent crashes | Supervision restarts it; existing sessions lost |

| Error | User Message | System Action |
|-------|--------------|---------------|
| Relay unreachable | "Shell not ready (relay connection failed)" | Retry 3x, then fail VM spawn |
| Hole punch failed | (silent) | Fall back to relay automatically |
| Invalid ticket | "Connection refused: invalid or expired ticket" | Log attempt, reject |
| TAP creation failed | "Failed to create network interface: [reason]" | Abort VM spawn, cleanup |
| Guest agent timeout | "VM shell not responding (timeout)" | Allow retry; offer serial console |

---

## 7. Success Metrics

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Time to shell | < 3 seconds | Timestamp from spawn request to shell prompt |
| Shell latency | < 100ms p95 | Measure keystroke round-trip |
| NAT traversal success | > 80% direct | Log hole punch success rate |
| Connection reliability | > 99% success | Track connection failures |
| Boot to ready | < 500ms | Timestamp from kernel boot to Iroh ready |

---

## 8. Phased Implementation Plan

### Phase 1: Guest Outbound Networking
**Goal:** VMs can reach the internet

**Deliverables:**
- [ ] TAP interface creation in VM spawn flow
- [ ] Iptables MASQUERADE setup in bootstrap-host.sh
- [ ] Guest network configuration (static IP, default route)
- [ ] Firecracker network-interface config
- [ ] Test: `curl https://example.com` works from guest
- [ ] Documentation: networking troubleshooting guide

**Dependencies:** None (extends existing VM spawn)

**Estimated complexity:** Medium

---

### Phase 2: Iroh Shell Server
**Goal:** Interactive shell accessible via Iroh ticket

**Deliverables:**
- [ ] Add `iroh-net` to guest agent Cargo.toml
- [ ] **Measure binary size impact** (before/after iroh-net)
- [ ] Keypair handling:
  - [ ] Generate on boot by default
  - [ ] Support pre-generated key via `/etc/mjolnir/iroh.key`
  - [ ] Log key generation with pubkey (INFO level)
- [ ] PTY allocation in guest agent
- [ ] Iroh endpoint initialization on agent boot
- [ ] Ticket generation and vsock `iroh_ready` message:
  ```json
  {"type": "iroh_ready", "node_id": "...", "ticket": "...", "generated_key": true}
  ```
- [ ] Shell connection handler (accept QUIC, spawn PTY)
- [ ] Host-side: handle `iroh_ready`, cache ticket in VM registry
- [ ] Host-side: `Mjolnir.VM.await_shell/2` API
- [ ] Test: connect to shell using ticket from different network
- [ ] Test: interactive apps (vim, htop) work correctly

**Dependencies:** Phase 1 (guest needs outbound for Iroh relay)

**Estimated complexity:** High

---

### Phase 3: Client Tooling
**Goal:** Easy-to-use shell client

**Deliverables:**
- [ ] CLI tool: `mjolnir shell <vm-id>` or `mjolnir connect <ticket>`
- [ ] Elixir API: `Mjolnir.VM.shell(vm_id)`
- [ ] File transfer: `mjolnir cp local:file vm:path`
- [ ] Session listing: see active connections
- [ ] Graceful disconnect handling

**Dependencies:** Phase 2

**Estimated complexity:** Medium

---

### Phase 4: VM↔VM Connectivity
**Goal:** Any VM can connect to any other VM

**Deliverables:**
- [ ] Service advertisement protocol (publish port + metadata)
- [ ] Service discovery (find services by capability/name)
- [ ] Port forwarding over Iroh QUIC streams
- [ ] Cross-host connection testing
- [ ] Same-host optimization (detect and use faster path)

**Dependencies:** Phase 2

**Estimated complexity:** High

---

### Phase 5: DNS & Discovery
**Goal:** Human-friendly VM addressing

**Deliverables:**
- [ ] Integrate with Iroh DNS (pkarr)
- [ ] Publish VM names: `myvm.mjolnir.local` → node_id
- [ ] Service discovery by name
- [ ] Integration with Elixir cluster for Mjolnir-wide discovery

**Dependencies:** Phase 4

**Estimated complexity:** Medium

---

## 9. Decisions & Open Questions

### Resolved

- [x] **Relay hosting:** Use n0's public relays (free & available). Self-hosted relay is future optimization if needed.
- [x] **Keypair management:** Generate on boot by default; support passing pre-generated key via config. Log key generation with pubkey. Return node_id + ticket via vsock `iroh_ready` message.
- [x] **Guest agent size:** Measure the bloat from iroh-net, but not a blocker. Track in Phase 2 deliverables.

### Open

- [ ] **Session persistence:** If VM is checkpointed with active shell, what happens on restore? (Probably: sessions die, must reconnect — Iroh state won't survive checkpoint)
- [ ] **Rate limiting:** Should we limit connections per VM to prevent abuse? (Defer until needed)

---

## 10. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-28 | Initial specification |
| 1.1 | 2026-01-28 | Resolved open questions: n0 relays, keypair handling, binary size measurement |

---

## Next Steps

1. Review spec with stakeholders
2. Resolve open questions
3. Run `/plan iroh-shell` to create technical implementation plan
4. Start with Phase 1 (networking) as it unblocks everything else

---

*Specification created with SDD methodology*
