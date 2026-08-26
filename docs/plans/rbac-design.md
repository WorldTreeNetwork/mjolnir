# Authorization Design for Mjolnir

Protocol-tier format (Biscuit as the agency token, identity vs
agency vs Recrypt data-access):
[`identikey-capability-v1.md`](https://github.com/identikey/identikey-protocol/blob/main/docs/standards/identikey-capability-v1.md)
in `identikey-protocol`. This file is the Mjolnir application
profile (facts, phases, Elixir/guest wiring).

## Philosophy

Mjolnir's authorization is evolving from centralized identity-based access control
toward **cryptographic capability tokens** with rights attenuation. The core principle:

> A capability token is a self-contained proof of authorization. The holder can
> exercise the rights it encodes, create strictly weaker versions of it, and share
> those with others — all without involving the server or an identity provider.

OIDC remains as the **identity bootstrap** — how you initially prove who you are and
receive your root capabilities. But once you hold a capability, you operate in a
decentralized authorization model where the math is the authority, not the server.

## Current State (Phase 0)

Mjolnir uses scope-based authorization with JWT claims. The `scope` claim is a
space-separated string of permissions checked per-endpoint via `require_scope/2`.

### Scope Inventory

| Scope | Endpoints | Description |
|-------|-----------|-------------|
| `vms:spawn` | POST /api/vms | Create new VMs |
| `vms:read` | GET /api/vms, GET /api/vms/:id, GET /api/dormant | List and inspect VMs |
| `vms:exec` | POST /api/vms/:id/exec, POST /api/vms/:id/message | Execute commands and send messages |
| `vms:stop` | DELETE /api/vms/:id | Stop/destroy VMs |
| `pty:connect` | GET /api/vms/:id/ticket, GET /api/vms/:id/await-pty | PTY/Iroh connection |
| `terminal:read` | GET /api/vms/:id/terminal/:name, GET /api/vms/:id/terminal | Read output, list sessions |
| `terminal:write` | POST /api/vms/:id/terminal/\*, DELETE /api/vms/:id/terminal/:name | Open, send, close sessions |
| `snapshots:create` | POST /api/vms/:id/snapshot | Create snapshots |
| `snapshots:read` | GET /api/snapshots, GET /api/snapshots/:name | List and inspect snapshots |
| `snapshots:delete` | DELETE /api/snapshots/:name | Delete snapshots |

### Authorization Layers

1. **Authentication** (`Mjolnir.API.Auth`) — Verifies JWT or localhost bypass
2. **Scope check** (`require_scope/2`) — Ensures the token has the required scope
3. **Ownership policy** (`Mjolnir.Policy.VM`, `Mjolnir.Policy.Snapshot`) — Resource-level owner check

### Localhost Bypass

Connections from `127.0.0.1` / `::1` bypass JWT auth and receive all scopes + `user_id: "localhost"`.
The policy layer grants localhost full access to all resources regardless of ownership.
This remains unchanged across all phases — it is an honest ops backdoor for a single-server system.

### The Sharing Gap

The fundamental limitation: `Policy.VM` authorizes resource actions via strict owner_id
equality (`uid == oid`). There is no delegation mechanism. Sharing access to a VM requires
either (a) sharing OIDC credentials (insecure), (b) server admin intervention (doesn't
scale), or (c) Iroh tickets with zero auth (too permissive). Capability tokens solve this.

---

## Capability Token Design

### Why Biscuit

After evaluating Macaroons, UCANs, Biscuit, and custom Ed25519 tokens:

| System | Attenuation | Elixir Ecosystem | Rust Ecosystem | Offline Verify | Expressiveness |
|--------|-------------|------------------|----------------|----------------|----------------|
| Macaroons | HMAC caveats | Dead (2017) | Stale (2021) | Partial | Opaque strings |
| UCAN | JWT subset | None (from scratch) | Reasonable | Full | Flat abilities |
| **Biscuit** | **Datalog checks** | **Rustler NIF** | **Production (Clever Cloud)** | **Full** | **Datalog rules** |
| Custom | Roll your own | N/A | N/A | Full | Whatever you build |

**Biscuit wins** because:
- **Datalog authorization** maps directly onto Mjolnir's existing pattern-matched policies
- **Rust-native** (`biscuit-auth` crate) — the guest agent can verify capabilities offline
- **Elixir integration** via Rustler NIF (proven pattern, we already have the Rust toolchain)
- **Rights attenuation** is a first-class primitive, not bolted on
- **Compact tokens** (~400-600 bytes with 3 attenuations, well under HTTP header and vsock frame limits)

### Anatomy of a Mjolnir Capability

A Biscuit token has an **authority block** (signed by the server's Ed25519 key) and
zero or more **attenuation blocks** (appended by anyone holding the token):

```
// Authority block — minted by server at VM spawn time
// Signed with server's Ed25519 private key
authority {
  vm("vm-abc-123");
  owner("user-42");
  right("vm-abc-123", "exec");
  right("vm-abc-123", "read");
  right("vm-abc-123", "stop");
  right("vm-abc-123", "snapshot");
  right("vm-abc-123", "terminal:read");
  right("vm-abc-123", "terminal:write");
  right("vm-abc-123", "pty");
  right("vm-abc-123", "message");
}

// Attenuation block — appended by the token holder (no server needed)
check if time($t), $t < 2026-03-14T00:00:00Z;
check if operation($op), $op in ["exec", "terminal:read"];
check if vm_id($id), $id == "vm-abc-123";
```

The server verifies: (1) the Ed25519 signature chain is valid, (2) all Datalog checks
pass when evaluated against the request facts. The holder can add checks but never
remove them — this is what makes attenuation monotonic and safe.

### Root Capabilities

When a VM is spawned, the server mints a root Biscuit encoding all rights for that VM.
This is returned alongside the VM metadata in the spawn response.

When a snapshot is created, the server mints a capability for that snapshot.

The root capability is the **maximum authority** for that resource. Everything else
is derived from it via attenuation.

### Rights Attenuation Examples

#### Share exec-only access for 2 hours

User A holds root cap for VM X. They attenuate (client-side, no server call):

```
// Appended by User A
check if time($t), $t < 2026-03-12T20:00:00Z;
check if operation($op), $op in ["exec", "terminal:read"];
```

Send the attenuated token to User B. User B presents it to the API. Done.

#### AI agent: spawn from snapshot, max 3 VMs, 1-hour TTL

```
// Authority: server mints a spawn capability
authority {
  right("spawn", "from_snapshot", "my-base-image");
}

// Attenuation: user restricts for the agent
check if time($t), $t < 2026-03-12T19:00:00Z;
check if snapshot($s), $s == "my-base-image";
check if spawn_count($n), $n < 3;   // server injects fact at verify time
check if vm_ttl($ttl), $ttl <= 3600; // server enforces max lifetime
```

Note: `spawn_count` requires a server-side fact (stateful). This is the honest
trade-off — resource limits need state. Time bounds and operation restrictions are
purely offline.

#### VM-to-VM delegation chain

VM A (owned by Alice) spawns child VM B and delegates a subset of its own capability:

```
// VM A attenuates its root cap for VM B
check if vm_id($id), $id in ["vm-a-uuid", "vm-b-uuid"];
check if operation($op), $op in ["exec", "message"];
```

VM B receives this via `deliver_message` over vsock. VM B can further attenuate for
a grandchild VM C, but can never escalate beyond what VM A granted. Each delegation
hop adds ~100-150 bytes to the token.

---

## Bridging OIDC and Capabilities

The two paradigms coexist. OIDC is the on-ramp; capabilities are the highway.

### Bootstrap Flow

```
   User                    OIDC Provider              Mjolnir Server
    |                          |                           |
    |-- Device Auth Grant ---->|                           |
    |<--- Access Token (JWT) --|                           |
    |                          |                           |
    |--- POST /api/vms  (JWT) --------------------------->|
    |                          |     verify JWT identity   |
    |                          |     mint root Biscuit     |
    |<--- { vm_id, capability: "<biscuit>" } -------------|
    |                                                      |
    |  (from here, no more OIDC needed)                    |
    |                                                      |
    |--- GET /api/vms/:id  (Biscuit) -------------------->|
    |                          |     verify Ed25519 sig    |
    |                          |     evaluate Datalog      |
    |<--- { vm details } ---------------------------------|
    |                                                      |
    |  (attenuate locally, share with others)               |
    |--- attenuate(cap, {exec only, 2hr}) --> friend_cap   |
    |                                                      |
```

### When Each Paradigm Applies

| Scenario | Auth Mechanism | Why |
|----------|---------------|-----|
| Initial login | OIDC JWT | Need to establish identity to mint root caps |
| API calls on own VMs | Biscuit (or JWT for backward compat) | Capability is more expressive |
| Sharing access with another user | Attenuated Biscuit | No server involvement needed |
| VM-to-VM messaging | Biscuit | VMs don't have OIDC identities |
| Iroh direct connection | Biscuit (embedded in ticket) | Guest agent verifies offline |
| AI agent delegation | Attenuated Biscuit | Fine-grained, time-bounded, self-contained |
| Localhost ops | Bypass (no token) | Trusted local path, unchanged |

### Capabilities Without OIDC

Some paths never touch OIDC at all:

- **VM-to-VM communication**: VM A holds a capability that authorizes messaging
  to VM B, issued by B's owner via attenuation. No OIDC identity needed.
- **Iroh direct connections**: The guest agent verifies the Biscuit's Ed25519
  signature using the server's public key (injected at boot). No call home.
- **Pre-shared capabilities**: A user can generate an attenuated capability URL
  and share it out-of-band. The recipient never authenticates via OIDC — the
  capability *is* the authorization.

---

## Iroh Ticket Integration

Iroh connection tickets are already a form of bearer capability — anyone with the
`EndpointAddr` JSON can connect to a VM's shell via QUIC with zero auth. This is
the biggest security gap in the current system.

### Evolution

**Today**: Iroh ticket = connectivity only, no authorization. Separate from API auth.

**Phase 2**: Capability verification on Iroh connections. Client sends a Biscuit as
the first frame after QUIC handshake (before the `Hello` frame). Guest agent verifies
Ed25519 signature offline using the server's public key.

**Phase 3**: Capability *becomes* the ticket. Iroh connection info embedded as
Biscuit facts:

```
authority {
  iroh_addr("node-id-xyz", "relay.example.com");
  right("vm-abc-123", "pty");
  right("vm-abc-123", "terminal:read");
}
```

One token grants both connectivity and authorization. Attenuate it to share
time-bounded, read-only terminal access to a specific VM — the recipient gets
everything they need in a single token.

---

## Revocation

Capabilities are bearer tokens — revocation without a central authority is the
hard problem. Three approaches, layered:

### 1. Short-Lived Tokens (default)

Set expiry to 1-4 hours via Datalog check. For most sharing scenarios, natural
expiration is sufficient. This is the simplest and should be the default for all
attenuated (shared) capabilities.

Root capabilities issued at VM spawn can be long-lived (or match VM lifetime)
since they're held by the owner.

### 2. Epoch-Based Rotation (emergency revoke)

Each VM has a `capability_epoch` counter in its GenServer state. Bumping the epoch
invalidates all outstanding capabilities for that VM. The authority block includes
the epoch:

```
authority {
  vm("vm-abc-123");
  epoch("vm-abc-123", 1);
}

// Server injects current epoch as fact at verify time
// If authority epoch < current epoch, token is rejected
```

This is all-or-nothing (revokes all shared access to a VM), but it's O(1) and
trivial to implement.

### 3. Revocation ID Bloom Filter (selective, future)

Each capability gets a unique `revocation_id`. The server maintains a bloom filter
of revoked IDs, distributed to guest agents periodically via vsock (the
`configure_identity` message is precedent for pushing config to guests). False
positives cause re-verification against server, not denial.

Defer this to Phase 3 — short-lived tokens + epoch rotation cover the common cases.

---

## Implementation Phases

### Phase 1: Dual-Mode Auth (non-breaking)

**Goal**: Introduce Biscuit tokens alongside existing JWT auth. No breaking changes.

- Add `biscuit-auth` Rustler NIF to Elixir host
- Generate Ed25519 keypair at server startup, store in config
- Mint root Biscuit on VM spawn, return in response (new field)
- Extend `Mjolnir.API.Auth` to accept `Authorization: Bearer biscuit:<b64>`
- Policy layer gets new clause: `authorize(action, %{capability: biscuit}, resource)`
  that evaluates the Biscuit Datalog instead of checking owner_id
- Existing JWT auth continues to work identically
- CLI client (`mjolnir`) stores Biscuit alongside VM metadata

### Phase 2: Capability-Aware Guest Agent

**Goal**: Guest agent verifies capabilities offline on Iroh connections.

- Add `biscuit-auth` to guest agent `Cargo.toml`
- Extend `configure_identity` to include server Ed25519 public key
- Add capability verification frame to Iroh connection protocol
- Client sends Biscuit before `Hello` frame; guest agent verifies signature + Datalog
- Reject Iroh connections without valid capability (closes the zero-auth gap)

### Phase 3: Capability-Native Operations

**Goal**: Capabilities are the primary authorization mechanism.

- VM-to-VM messaging uses capabilities instead of owner_id checks
- Dormant VM restoration accepts capabilities for wake-up authorization
- Iroh tickets embed capability tokens (unified ticket format)
- `mjolnir cap attenuate` CLI command for user-friendly capability creation
- Bloom filter revocation for selective invalidation
- Agent SDK exposes capability attenuation for in-VM use

---

## Token Sizing

| Token Type | Typical Size | Fits In |
|------------|-------------|---------|
| Root Biscuit | 200-300 bytes | HTTP header (8KB), vsock frame (64KB) |
| 3 attenuations | 400-600 bytes | HTTP header, vsock frame |
| 5-deep delegation chain | 800-1200 bytes | HTTP header, vsock frame |
| Unified Iroh+cap ticket | 500-800 bytes | QUIC frame (1MB), QR code (2.9KB) |

No size concerns for any realistic scenario. Ed25519 signature verification is
~50-100 microseconds per hop — a 5-deep chain verifies in <1ms.

---

## Open Questions

- Should root capabilities be bound to the owner's public key (so only the owner
  can attenuate), or bound to the server key (so anyone holding the token can
  attenuate)? Server-key binding is simpler and more aligned with the "capability
  as bearer token" model.
- How do we handle capability discovery? If a user loses their root Biscuit, can
  the server re-mint it? (Yes, if they re-authenticate via OIDC — the server is
  the authority for root capabilities.)
- Should the CLI store capabilities in the TOML profile, or in a separate
  capability keychain file?
- What's the UX for attenuating and sharing? `mjolnir cap share vm-abc --ops exec,read --ttl 2h`
  that outputs a URL/token the recipient can use directly?
