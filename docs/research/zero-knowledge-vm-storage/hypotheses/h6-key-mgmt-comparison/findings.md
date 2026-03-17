# H6: Key Management Comparison — FOKS vs Recrypt vs Custom Identikey

## Summary

Three options exist for Mjolnir's key management layer: FOKS (Federated Open Key
Service), Recrypt's built-in key management, and custom extensions to the existing
Identikey OIDC provider. After analyzing feature coverage, crypto compatibility,
integration complexity, and strategic alignment, the recommendation is a **hybrid
architecture**: use FOKS for key lifecycle management (device/user/team hierarchy,
rotation, discovery, federation) and Recrypt for cryptographic operations (proxy
re-encryption, symmetric encryption). Custom Identikey extensions serve as the
identity bridge between the two. This is not over-engineering — the three systems
handle orthogonal concerns with minimal overlap.

## Feature Matrix

| Capability | FOKS | Recrypt | Custom Identikey |
|------------|------|---------|------------------|
| **Per-device keys** (never leave machine) | Yes — device keys in OS keychain | Yes — client holds secret keys | Must build from scratch |
| **Per-user keys (PUKs)** for DEK wrapping | Yes — rotating PUK sequence | Yes — per-user keypair | Must build from scratch |
| **Per-team keys (PTKs)** for shared access | Yes — recursive PTK nesting | No — would need external team key layer | Must build from scratch |
| **Device revocation + cascading re-key** | Yes — automatic PUK rotation triggers PTK cascade | No — no device management concept | Must build from scratch |
| **Key discovery** (find user's public key) | Yes — signature chains via federated protocol | No — assumes out-of-band key exchange | Could add key registry endpoints |
| **OIDC identity binding** | No — has its own identity model | No — external auth service assumed | Native — Keycloak is the OIDC provider |
| **Proxy re-encryption** | No | Yes — OpenFHE BFVrns lattice-based PRE | No |
| **Post-quantum readiness** | Yes — Curve25519 + ML-KEM | Yes — lattice-based (BFVrns) + ML-DSA-87 | Must build from scratch |
| **Client-side wallet / agent** | Yes — `foks` agent daemon (like ssh-agent) | Yes — CLI holds keys locally | Must build from scratch |
| **Federation** (cross-node key discovery) | Yes — native federated protocol | No — single-server assumed | No |
| **Signature chains** (tamper-evident history) | Yes — linear signature chains + Merkle trees | No | No |
| **Symmetric encryption** | No — key management only | Yes — XChaCha20 bulk encryption | No |
| **HDprint identifiers** (human-readable key IDs) | No | Yes — self-correcting Base58 IDs | No |
| **Multi-signature authorization** | No | Yes — all keys must sign | No |
| **Merkle tree accountability** | Yes — prevents server from forking chains | No | No |
| **Maturity** | Production-quality, MIT, Go, small team | Phase 0 complete, Phase 1-8 ahead (10-12 wks), Rust | Keycloak is mature; extensions are greenfield |
| **Language** | Go | Rust | Java (Keycloak) |

### Coverage Summary

- **FOKS** covers 8 of 10 requirements out of the box (missing: PRE, OIDC binding)
- **Recrypt** covers 5 of 10 (missing: team keys, device revocation, key discovery, OIDC binding, federation)
- **Custom Identikey** covers 1 of 10 out of the box (OIDC binding); everything else is greenfield

## Crypto Compatibility Analysis

### The Two-Keypair Problem

FOKS and Recrypt use fundamentally different post-quantum cryptographic schemes:

| System | Key Exchange / Encryption | Signatures | Lattice Basis |
|--------|--------------------------|------------|---------------|
| FOKS | Curve25519 + ML-KEM (NIST standard) | Ed25519 | Module lattices (ML-KEM) |
| Recrypt | OpenFHE BFVrns (homomorphic) | Ed25519 + ML-DSA-87 | Ring-LWE lattices (BFV) |

**These cannot share a keypair.** ML-KEM is a key encapsulation mechanism designed for
key exchange. BFVrns is a fully homomorphic encryption scheme that enables proxy
re-encryption — a fundamentally different algebraic structure. The user needs two
keypairs:

1. **FOKS keypair** (Curve25519 + ML-KEM): For key hierarchy, device management,
   PUK/PTK wrapping, and federated key discovery.
2. **Recrypt keypair** (BFVrns lattice): For proxy re-encryption operations on
   wrapped DEKs.

### Is the Two-Keypair Model Acceptable?

Yes. This is standard practice in cryptographic systems:

- **SSH** uses separate keys for authentication (Ed25519) and encryption (X25519)
- **PGP** uses separate subkeys for signing, encryption, and authentication
- **TLS** uses separate keys for key exchange (ECDHE) and authentication (RSA/ECDSA)

The FOKS keypair handles the **key lifecycle** (who holds which keys, rotation,
discovery). The Recrypt keypair handles the **re-encryption operation** (transforming
a wrapped DEK from Alice's key to Bob's key without decrypting). These are distinct
cryptographic operations with different algebraic requirements.

### Key Hierarchy Composition

```
FOKS Device Key (Curve25519 + ML-KEM)
  └── FOKS PUK (rotates on device revocation)
        ├── Wraps per-snapshot DEKs (XChaCha20 symmetric keys)
        ├── Wraps user's Recrypt private key (so all devices can access it)
        └── FOKS PTK (per-team, rotates on membership change)
              └── Wraps team-shared DEKs

Recrypt Keypair (BFVrns lattice)
  ├── Generated once per user, wrapped with FOKS PUK
  ├── Used to generate re-encryption keys: rk_A→B
  └── Used by proxy to transform wrapped DEKs between users

Relationship:
  - FOKS PUK wraps the Recrypt private key → all user's devices can PRE
  - FOKS PUK wraps snapshot DEKs → standard access
  - Recrypt re-encrypts FOKS-wrapped DEKs → sharing without decryption
  - When FOKS PUK rotates, Recrypt key is re-wrapped with new PUK
```

**Critical insight**: The Recrypt private key is itself wrapped by the FOKS PUK. This
means device revocation (which rotates the PUK) automatically re-wraps the Recrypt
key. The user never needs to manage Recrypt keys directly — FOKS handles the lifecycle,
Recrypt handles the math.

### Can FOKS PTK-Based Sharing Replace PRE?

FOKS's team key (PTK) model handles sharing differently from PRE:

| Aspect | FOKS PTK Sharing | Recrypt PRE Sharing |
|--------|-----------------|-------------------|
| **Mechanism** | DEK wrapped with team PTK; all members unwrap | DEK re-encrypted from Alice's key to Bob's key |
| **Server knowledge** | Server sees who is in the team (membership) | Server sees re-encryption key but not DEK |
| **Granularity** | Team-level (all members get same access) | Per-user, per-snapshot |
| **Revocation** | Remove from team → PTK rotates → new DEKs only | Delete re-encryption key → future shares blocked |
| **Zero-knowledge** | Server knows team membership graph | Server knows nothing about key relationships |
| **Ad-hoc sharing** | Must create a team for any sharing | Generate rk_A→B for one-off shares |

**Both are needed.** PTK sharing is right for persistent teams (an org's dev team
shares all staging snapshots). PRE is right for ad-hoc, zero-knowledge sharing (Alice
shares one snapshot with an external contractor without revealing anything to the
server).

## Integration Architecture

### Option A: FOKS Only (No PRE)

```
┌──────────────────────────────────────────────────┐
│ User's Device                                     │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Identikey│  │ FOKS     │  │ mjolnir CLI    │  │
│  │  (OIDC)  │  │ agent    │  │                │  │
│  └────┬─────┘  └────┬─────┘  └───────┬────────┘  │
│       │identity     │PUK/PTK        │             │
└───────┼─────────────┼───────────────┼─────────────┘
        │             │               │
        ▼             ▼               ▼
┌──────────────────────────────────────────────────┐
│ Mjolnir Server                                    │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Identikey│  │ FOKS     │  │ Mjolnir        │  │
│  │ (Keyclk) │  │ server   │  │ (Elixir)       │  │
│  └──────────┘  └──────────┘  └────────────────┘  │
│                                                    │
│  Integration: Go sidecar, HTTP/gRPC API            │
│  OIDC→FOKS bridge: JWT claim with FOKS public key  │
└──────────────────────────────────────────────────┘

Effort: Medium (3-4 weeks)
  - Deploy FOKS server as Docker sidecar
  - Build Rust FOKS client for mjolnir CLI (or shell out to foks binary)
  - Bridge Identikey OIDC identity to FOKS identity
  - Integrate PUK/PTK key lookups into Mjolnir's Elixir API

Limitation: No proxy re-encryption. Sharing is team-based only.
Ad-hoc sharing requires creating a team (even for 1:1 shares).
```

### Option B: Recrypt Only (No FOKS)

```
┌──────────────────────────────────────────────────┐
│ User's Device                                     │
│  ┌──────────┐  ┌──────────────────────────────┐   │
│  │ Identikey│  │ mjolnir CLI + recrypt keys   │   │
│  │  (OIDC)  │  │ (BFVrns keypair, local)      │   │
│  └────┬─────┘  └────────────┬─────────────────┘   │
│       │identity             │                      │
└───────┼─────────────────────┼──────────────────────┘
        │                     │
        ▼                     ▼
┌──────────────────────────────────────────────────┐
│ Mjolnir Server                                    │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Identikey│  │ Recrypt  │  │ Mjolnir        │  │
│  │ + key    │  │ proxy    │  │ (Elixir)       │  │
│  │ registry │  │ (Rust)   │  │                │  │
│  └──────────┘  └──────────┘  └────────────────┘  │
│                                                    │
│  Integration: Rust sidecar (same language as CLI)  │
│  Key registry: custom Identikey extension          │
└──────────────────────────────────────────────────┘

Effort: High (6-8 weeks) — Recrypt is Phase 0 of 8
  Must build from scratch:
  - Device key management
  - Key rotation / revocation cascading
  - Team key hierarchy
  - Key discovery protocol
  - Federation
  - Signature chains / tamper evidence

Advantage: Tight Rust integration (CLI, guest agent, proxy — all Rust).
Same team controls everything.

Risk: Recrypt is 10-12 weeks from production. Building the missing
key lifecycle features on top adds another 8-12 weeks. Total: 5-6 months.
```

### Option C: Custom Identikey Extensions

```
┌──────────────────────────────────────────────────┐
│ User's Device                                     │
│  ┌──────────┐  ┌──────────────────────────────┐   │
│  │ Identikey│  │ mjolnir CLI + custom wallet  │   │
│  │  (OIDC)  │  │ (Ed25519/ML-KEM keypair)     │   │
│  └────┬─────┘  └────────────┬─────────────────┘   │
│       │identity + pub key   │                      │
└───────┼─────────────────────┼──────────────────────┘
        │                     │
        ▼                     ▼
┌──────────────────────────────────────────────────┐
│ Mjolnir Server                                    │
│  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ Identikey         │  │ Mjolnir              │  │
│  │ + key registry    │  │ (Elixir)             │  │
│  │ + device mgmt     │  │                      │  │
│  │ + team keys       │  │                      │  │
│  └──────────────────┘  └──────────────────────┘  │
│                                                    │
│  Integration: Keycloak SPI extensions (Java)       │
│  Everything custom, everything owned               │
└──────────────────────────────────────────────────┘

Effort: Very High (12-16 weeks)
  Must build everything:
  - Key hierarchy (device → PUK → PTK)
  - Rotation and cascading revocation
  - Signature chains and tamper evidence
  - Key discovery protocol
  - Client wallet CLI
  - Federation protocol
  - Keycloak SPI extensions (Java)

Advantage: Full control. No external dependencies.

Risk: This is reimplementing FOKS from scratch in a fourth language (Java).
Keycloak SPIs are not designed for key management — they handle authn/authz.
Shoe-horning cryptographic key lifecycle into OIDC claims is architecturally wrong.
```

### Option D: FOKS + Recrypt Hybrid (Recommended)

```
┌──────────────────────────────────────────────────┐
│ User's Device                                     │
│  ┌──────────┐  ┌────────┐  ┌──────────────────┐  │
│  │ Identikey│  │ FOKS   │  │ mjolnir CLI      │  │
│  │  (OIDC)  │  │ agent  │  │ + recrypt keys   │  │
│  └────┬─────┘  └───┬────┘  └────────┬─────────┘  │
│       │            │                │              │
│       │identity    │PUK/PTK        │DEK ops       │
└───────┼────────────┼───────────────┼──────────────┘
        │            │               │
        ▼            ▼               ▼
┌──────────────────────────────────────────────────┐
│ Mjolnir Server                                    │
│  ┌──────────┐  ┌────────┐  ┌────────┐  ┌──────┐ │
│  │ Identikey│  │ FOKS   │  │Recrypt │  │Mjolnr│ │
│  │ (OIDC)  │  │ server │  │ proxy  │  │(Elix)│ │
│  └──────────┘  └────────┘  └────────┘  └──────┘ │
│                                                    │
│  FOKS: key lifecycle (Go sidecar)                  │
│  Recrypt: PRE operations (Rust sidecar)            │
│  Identikey: OIDC bridge (existing)                 │
│  Mjolnir: orchestration (Elixir, existing)         │
└──────────────────────────────────────────────────┘

Effort: Medium-High (5-6 weeks, parallelizable)
  Week 1-2: Deploy FOKS server, build OIDC→FOKS bridge
  Week 2-3: Rust FOKS client in mjolnir CLI (key lookup, PUK operations)
  Week 3-5: Integrate Recrypt PRE for ad-hoc sharing (as Recrypt matures)
  Week 5-6: Team sharing via FOKS PTKs, federation setup

Advantage: Each system does what it's best at. No reinventing wheels.

Trade-off: Two sidecars (Go + Rust). More moving parts in deployment.
But Docker Compose makes this operationally simple.
```

## The Hybrid Model in Detail

### Responsibility Split

```
Concern                    │ Handled By      │ Why
───────────────────────────┼─────────────────┼──────────────────────────
Device key generation      │ FOKS agent      │ OS keychain integration
Device revocation          │ FOKS            │ Cascading PUK rotation
PUK management             │ FOKS            │ Multi-device sync
PTK management             │ FOKS            │ Recursive team nesting
Key discovery              │ FOKS            │ Federated protocol
Signature chains           │ FOKS            │ Tamper-evident key history
Merkle accountability      │ FOKS            │ Server honesty enforcement
DEK wrapping (standard)    │ FOKS PUK        │ Curve25519 + ML-KEM
DEK re-encryption (share)  │ Recrypt         │ BFVrns PRE
Symmetric encryption       │ XChaCha20       │ libsodium secretstream
OIDC identity              │ Identikey       │ Existing provider
OIDC→FOKS bridge           │ Custom (small)  │ JWT claim + registration
Authorization              │ Biscuit         │ Datalog capability tokens
Content transport          │ Iroh            │ P2P encrypted blobs
```

### Data Flow: Spawn Encrypted VM

```
1. User runs `mjolnir spawn`
2. CLI authenticates with Identikey (OIDC device auth flow)
   → Receives JWT with `sub` claim
3. CLI contacts FOKS agent for user's PUK
   → FOKS agent returns PUK (Curve25519 + ML-KEM public key)
4. CLI sends POST /api/vms with JWT
5. Mjolnir server:
   a. Verifies JWT via Identikey
   b. Looks up user's PUK via FOKS server
   c. Generates random DEK (256-bit XChaCha20 key)
   d. Wraps DEK with user's PUK: wrapped_dek = ML-KEM.Encapsulate(PUK, DEK)
   e. Boots VM, stores wrapped_dek in snapshot metadata
   f. Returns { vm_id, wrapped_dek, biscuit }
6. CLI unwraps DEK using FOKS device key chain:
   PUK_private → DEK = ML-KEM.Decapsulate(PUK_sk, wrapped_dek)
7. CLI injects DEK into VM via Iroh (encrypted P2P channel)
8. Guest agent mounts encrypted overlay using DEK
```

### Data Flow: Share Snapshot (PRE)

```
1. Alice runs `mjolnir snap share my-snap --to bob@example.com`
2. CLI looks up Bob's FOKS PUK via federated key discovery
3. CLI looks up Bob's Recrypt public key (stored wrapped in Bob's FOKS PUK,
   published via FOKS key registry)
4. CLI generates re-encryption key:
   rk_A→B = Recrypt.rekeygen(alice_recrypt_sk, bob_recrypt_pk)
5. CLI sends rk_A→B + attenuated Biscuit to Mjolnir server
6. Server transforms wrapped DEK:
   wrapped_dek_bob = Recrypt.reencrypt(rk_A→B, wrapped_dek_alice)
7. Server stores access_grant in snapshot metadata
8. Bob receives notification, fetches snapshot:
   a. Bob's FOKS agent provides Recrypt private key
   b. DEK = Recrypt.decrypt(bob_recrypt_sk, wrapped_dek_bob)
   c. Bob decrypts snapshot stream with DEK
```

### Data Flow: Team Sharing (PTK)

```
1. Admin runs `mjolnir team create staging-access`
2. FOKS creates PTK, encrypted for all team members' PUKs
3. Admin runs `mjolnir snap share my-snap --to-team staging-access`
4. CLI wraps DEK with team PTK (no PRE needed — standard encryption)
5. Any team member's device can unwrap PTK → unwrap DEK
6. When a member is removed:
   a. FOKS rotates PTK automatically
   b. New snapshots use new PTK
   c. Old snapshots remain accessible (PTK chain preserves history)
```

## Maturity and Risk Assessment

| Factor | FOKS | Recrypt | Custom Identikey |
|--------|------|---------|------------------|
| **Code maturity** | Production-quality, MIT license | Phase 0 complete, 10-12 weeks to prod | Greenfield (0 code) |
| **Team** | Keybase co-founders (Max Krohn et al.) | IdentiKey team (same as Mjolnir) | IdentiKey team |
| **Language risk** | Go — needs sidecar or FFI for Elixir/Rust | Rust — native to CLI and guest agent | Java — another language boundary |
| **Dependency risk** | External project, small team, could stagnate | Internal project, full control | No dependency, full control |
| **Protocol stability** | Federated protocol designed for stability | Wire format not yet finalized | N/A |
| **Production deployments** | New project, limited production use | Zero production deployments | Keycloak is battle-tested; extensions are not |

### Risk Mitigation

**FOKS stagnation risk**: FOKS is MIT-licensed Go. If the project stagnates, the
IdentiKey team can fork and maintain the relevant components. The key primitives
(Curve25519, ML-KEM, signature chains) use standard algorithms — they are not
proprietary. The protocol specification is public, so a Rust reimplementation of the
client-side primitives is feasible (estimated 4-6 weeks for a minimal client).

**Recrypt delay risk**: Recrypt is 10-12 weeks from production. If it slips, Mjolnir
can ship without PRE initially. FOKS PTK-based team sharing covers the most common
sharing scenario. PRE adds ad-hoc zero-knowledge sharing, which is valuable but not
blocking for MVP.

**Integration complexity risk**: Two sidecars (FOKS Go + Recrypt Rust) alongside
Mjolnir (Elixir). This is manageable with Docker Compose but adds operational surface.
Mitigation: deploy FOKS and Recrypt as systemd services alongside Mjolnir, same
pattern as virtiofsd.

## The Proxy Re-encryption Question

### Is FOKS's PTK-based sharing sufficient, or is PRE genuinely needed?

**PTK sharing is sufficient for 80% of use cases.** Teams sharing snapshots within an
organization is the primary scenario, and FOKS PTKs handle it elegantly with automatic
key rotation on membership changes.

**PRE is needed for the remaining 20%:**

1. **Ad-hoc sharing with external users**: Sharing a snapshot with a contractor who
   is not on your FOKS server. PRE allows this without creating a team, without the
   server learning anything about the relationship, and without the recipient needing
   a FOKS account on your server (only a Recrypt keypair).

2. **Zero-knowledge sharing**: With PTKs, the FOKS server knows team membership.
   With PRE, the Mjolnir server sees only the re-encryption key — it cannot determine
   who the recipient is (the rk is opaque to the proxy).

3. **Biscuit-embedded key material**: PRE integrates naturally with Biscuit capability
   tokens. The re-encrypted wrapped DEK can be included as a Biscuit fact, creating
   a single self-contained token that grants both authorization and decryption ability.

4. **Time-bounded sharing**: Combined with Biscuit TTLs, PRE enables "share this
   snapshot for 24 hours" where the authorization expires but the re-encryption key
   is cryptographically bound to the Biscuit — no server-side revocation needed.

**Verdict**: Ship with FOKS PTKs first (Phase 2). Add Recrypt PRE when it matures
(Phase 3). The architecture supports both without conflict.

## Build vs Buy: Strategic Considerations

### The Digital Sovereignty Argument

IdentiKey's mission is digital sovereignty infrastructure. Owning the key management
stack (Recrypt + custom hierarchy) aligns with this mission. Depending on FOKS
introduces an external dependency controlled by a different team.

**Counter-argument**: Digital sovereignty does not require building every component
from scratch. It requires that users can self-host, audit, and fork every component.
FOKS is MIT-licensed, protocol-specified, and forkable. Using FOKS is as sovereign as
using Linux — you depend on an external project but retain full control.

**The real question**: Where should IdentiKey invest its engineering time?

- **Option 1**: Spend 12-16 weeks building FOKS-equivalent key management from scratch.
  Result: a custom system that does what FOKS already does, but with less testing,
  fewer edge cases handled, and no federation protocol.

- **Option 2**: Spend 3-4 weeks integrating FOKS, then invest the saved 8-12 weeks
  into Recrypt's unique PRE capabilities and Mjolnir's core VM fabric.
  Result: production key management sooner, plus differentiated PRE capabilities that
  no other system provides.

**Option 2 is strategically superior.** FOKS is commoditized infrastructure (key
hierarchy and rotation are solved problems). Recrypt's proxy re-encryption is the
differentiator — it enables zero-knowledge sharing that FOKS alone cannot provide.
Invest in the differentiator, not the commodity.

### Ownership Spectrum

```
Full ownership ◄──────────────────────────────► Full dependency

Custom Identikey    Recrypt       FOKS fork      FOKS upstream
(build all)         (own PRE,     (fork, own     (use as-is)
                     use FOKS     the code)
                     for rest)

                    ▲
                    │
              Recommended position
```

The recommended position: use FOKS upstream for key lifecycle, own Recrypt for PRE,
with the understood option to fork FOKS if the upstream project diverges from
Mjolnir's needs.

## What to Steal from FOKS Even If We Don't Use It

If the team decides against adopting FOKS as a dependency, these design patterns
should be replicated in any custom implementation:

### 1. Cascading Key Rotation on Device Revocation

FOKS's most valuable design: revoking a device automatically rotates the PUK, which
triggers PTK rotation across all teams. This eliminates the manual "re-key everything"
problem. Any custom implementation MUST have this property.

**Implementation sketch**: Maintain a `puk_generation` counter. Device revocation
increments the generation, generates a new PUK, and re-encrypts the PUK for all
remaining devices. Each team's PTK includes a `member_puk_generation` — when it detects
a stale generation, it triggers PTK rotation.

### 2. Signature Chains for Tamper Evidence

FOKS's signature chains prevent the server from backdating key operations or forking
the key history. Each key operation is signed with the previous key, creating a linear
chain that clients verify by replaying from genesis.

**Why this matters for Mjolnir**: Without signature chains, a compromised server could
replace a user's public key with an attacker's key, wrap future DEKs with the
attacker's key, and the user would never know. Signature chains make this detectable.

**Implementation sketch**: Each key operation produces a `SignedLink { operation,
prev_hash, signature(device_key) }`. Clients store the chain head hash locally and
verify continuity on each sync.

### 3. Merkle Tree Accountability

FOKS uses a Merkle tree to prevent the server from showing different chain states to
different clients (the "split-world" attack). The tree root is published, so any client
can verify they see the same state as every other client.

**Implementation sketch**: Server maintains a Merkle tree of all signature chain heads.
Clients request inclusion proofs when fetching keys. If two clients receive
inconsistent proofs, the server is provably dishonest.

### 4. PUK Encrypted for All Devices

FOKS's PUK is not stored on a single device — it is encrypted for every authorized
device's key. Adding a new device means re-encrypting the PUK for the new device set.
This gives seamless multi-device access without seed phrases or manual key export.

**Implementation sketch**: `encrypted_puk = { device_id → Encrypt(device_pk, puk_seed) }`
stored server-side. Each device decrypts its copy to derive the PUK.

### 5. Recursive Team Nesting

FOKS teams can contain other teams, with PTKs encrypted for member PTKs recursively.
This maps naturally onto organizational hierarchies: `org → department → team`.

**Implementation sketch**: A team member can be either a `User(puk)` or a `Team(ptk)`.
The PTK is encrypted for each member's key, regardless of type.

### 6. Federated Key Discovery Protocol

FOKS's federation model allows cross-server key lookup, similar to email's MX records.
For Mjolnir's multi-node future, this is essential — nodes need to discover users'
public keys on other nodes to enable cross-node snapshot sharing.

**Implementation sketch**: `user@node.example.com` → DNS SRV lookup →
`_foks._tcp.node.example.com` → FOKS server address → key chain fetch.

## Recommendation

### Primary: FOKS + Recrypt Hybrid (Option D)

**Phase 2 (Weeks 1-4)**: Integrate FOKS for key lifecycle management.
- Deploy FOKS server as Docker sidecar alongside Mjolnir
- Build OIDC → FOKS identity bridge (Identikey JWT `sub` → FOKS username)
- Implement minimal Rust FOKS client in `mjolnir` CLI (key registration, PUK lookup)
- Replace server-derived KEKs with FOKS PUKs for DEK wrapping
- Team creation and PTK-based sharing for persistent groups

**Phase 3 (Weeks 5-8)**: Integrate Recrypt for PRE (as Recrypt reaches Phase 4+).
- Deploy Recrypt proxy as Rust sidecar
- User's Recrypt keypair wrapped with FOKS PUK (managed automatically)
- Ad-hoc sharing via PRE: `mjolnir snap share --to user@other.node`
- Biscuit integration: re-encrypted DEK as capability fact

**Phase 5 (Weeks 12+)**: Federation.
- Each Mjolnir node runs a FOKS server
- Cross-node key discovery via FOKS federation protocol
- Cross-node PRE sharing via Recrypt + FOKS key lookup

### Rationale

1. **Time to production**: FOKS gives production key management in 3-4 weeks.
   Custom would take 12-16 weeks for equivalent capability.

2. **Separation of concerns**: FOKS handles key lifecycle (hard, solved problem).
   Recrypt handles PRE (differentiator, unique to IdentiKey). Biscuit handles
   authorization. Each system is best-in-class for its concern.

3. **Strategic alignment**: IdentiKey invests engineering time in Recrypt (the
   differentiator) rather than reimplementing FOKS (the commodity).

4. **Federation readiness**: FOKS's native federation maps directly onto Mjolnir's
   multi-node future. Building custom federation would add months.

5. **Risk mitigation**: FOKS is MIT-licensed and forkable. If it stagnates, the team
   can maintain a fork. Recrypt is internal and fully controlled.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| **A: FOKS only** | Simplest integration; production key mgmt fast; federation native | No PRE; ad-hoc sharing requires team creation; Go sidecar |
| **B: Recrypt only** | Same language (Rust); full ownership; PRE native | 5-6 months to feature parity with FOKS; must build key hierarchy, rotation, discovery, federation from scratch |
| **C: Custom Identikey** | Full control; no dependencies; exact fit | 12-16 weeks; reimplements solved problems; Java for key mgmt is architectural mismatch |
| **D: FOKS + Recrypt** | Best of both; fastest to production; clean separation | Two sidecars; two keypairs per user; Go + Rust + Elixir polyglot |

### The Honest Tension

The tension is **ownership vs velocity**. Building everything in-house (Recrypt +
custom hierarchy) gives maximum control and aligns with digital sovereignty messaging.
Using FOKS as a dependency introduces a risk that the upstream project could diverge,
stagnate, or introduce changes that conflict with Mjolnir's needs.

However, the sovereignty risk is mitigated by FOKS's MIT license and protocol-first
design. The velocity cost of building everything from scratch is real and significant:
3-4 months of engineering time that could be spent on Recrypt's PRE (the actual
differentiator) and Mjolnir's core VM fabric.

The recommendation is to **accept the FOKS dependency now**, with an explicit exit
plan (fork if needed), and invest the saved time in Recrypt and Mjolnir's unique
capabilities.

## Confidence

**High** for the hybrid recommendation. The separation of concerns is clean (key
lifecycle vs PRE vs authorization), the integration surfaces are well-defined
(sidecar HTTP APIs), and the fallback plan is concrete (fork FOKS if needed). The
main uncertainty is Recrypt's timeline — if it slips significantly, FOKS PTK sharing
alone covers the MVP sharing model.

## References

- [FOKS crypto architecture](https://foks.pub/docs/crypto/) — Key hierarchy, signature chains, Merkle trees, post-quantum (Curve25519 + ML-KEM)
- [FOKS federation architecture](https://foks.pub/docs/arch/) — Server trust model, cross-server teams, deployment patterns
- [FOKS source](https://github.com/foks-proj/go-foks) — MIT license, Go implementation
- [Recrypt](https://github.com/IdentiKey/recrypt) — OpenFHE BFVrns PRE, Phase 0 complete, 8 phases to production
- `docs/research/zero-knowledge-vm-storage/synthesis.md` — Overall ZK architecture, phase plan
- `docs/research/zero-knowledge-vm-storage/hypotheses/h5-client-key-wallet-oidc/findings.md` — FOKS evaluation, OIDC bridge design
- `docs/research/zero-knowledge-vm-storage/hypotheses/h2-proxy-reencryption-sharing/findings.md` — PRE composition with Biscuit
- `docs/plans/rbac-design.md` — Biscuit capability token design, OIDC bootstrap flow
- `native/mjolnir_client/src/auth.rs` — Current OIDC device auth flow (Identikey integration point)
- `native/mjolnir_client/src/config.rs` — Current CLI config (where key storage would integrate)
