# Zero-Knowledge VM Storage: Synthesis

> **See also:** `docs/encryption-and-security.md` for the consolidated security architecture that this research informed — three-tier storage model, cipher suite selection, and build phases.

## Key Findings

The research across five hypotheses converges on a clear architecture for achieving
zero-knowledge VM storage in Mjolnir, with an honest assessment of what's achievable
now versus what requires hardware evolution.

### 1. The Server Cannot Be Fully Blinded During Runtime (Without Hardware)

Mjolnir's virtio-fs architecture gives the host complete visibility into the guest
filesystem — virtiofsd serves every file operation [H3 §Evidence]. AMD SEV-SNP and
Intel TDX protect memory but **do not protect virtio-fs I/O** because it uses shared
memory buffers [H3 §Evidence]. True zero-knowledge runtime requires either:

- Moving to virtio-blk + dm-crypt (loses instant BTRFS reflink cloning)
- Waiting for Cloud Hypervisor's SEV-SNP on KVM to mature [H3 §Sources, CH issue #6653]

**However**, encryption at rest is highly valuable: VMs spend most of their time dormant
in Mjolnir's architecture. Encrypting snapshots and dormant state protects the majority
of the data lifecycle [H1 §Trust Model].

### 2. Envelope Encryption + Proxy Re-encryption Is the Architecture

The composition is clean and each piece handles one concern [H2 §Evidence]:

```
XChaCha20-Poly1305    = bulk data encryption (btrfs send streams)
FOKS PUKs/PTKs        = key management (device → user → team hierarchy)
Recrypt PRE           = zero-knowledge sharing (re-encrypt wrapped DEK)
Biscuit               = authorization (who can access what)
Iroh                  = transport (content-addressed encrypted blob transfer)
btrfs send/receive    = serialization (native BTRFS snapshot format)
```

**Critical insight**: Proxy re-encryption operates on the **wrapped symmetric key**
(~256 bits), not the multi-GB snapshot stream. This makes it practical — re-encrypting
takes milliseconds regardless of snapshot size [H2 §Performance].

### 3. XChaCha20-Poly1305 via libsodium secretstream Is the Right Cipher

The scientist agent confirmed with high confidence [H4]:

- XChaCha20 sustains ~2,500 MB/s; btrfs send bottlenecks at ~400 MB/s → **6.25x headroom**
- 192-bit nonce eliminates nonce management entirely (collision probability < 10^-47)
- libsodium `secretstream` handles chunked AEAD correctly (64KB chunks, ratcheted subkeys)
- **Rijndael-512 ("AES-512") is not viable**: no production library implements it, no hardware
  acceleration, and AES-256's post-quantum security (2^128 Grover ops) is already intractable [H4 §Findings]
- Encryption adds 0.024% space overhead (16-byte Poly1305 tag per 64KB chunk)

### 4. FOKS Is the Key Management Layer

FOKS (Federated Open Key Service, by Keybase co-founders) solves the hardest part of the
zero-knowledge model — key lifecycle management [H5]:

- **Device keys → PUKs → PTKs** maps directly onto Mjolnir's per-device → per-user → per-team model
- **Automatic cascading re-keying** on device revocation — no manual key rotation
- **Federated protocol** — each Mjolnir node can run a FOKS server
- **Signature chains + Merkle trees** prevent server tampering with key history
- **Post-quantum** (Curve25519 + ML-KEM)

FOKS replaces the need for a custom key wallet. The OIDC → FOKS bridge works by
registering the user's FOKS public key at first login via Identikey [H5 §OIDC Bridge].

### 5. Iroh DEK Injection Bypasses the Untrusted Host

The Iroh P2P channel (QUIC + TLS 1.3) is endpoint-to-endpoint encrypted and bypasses
vsock entirely [H1 §Key Injection]. The host cannot intercept DEK injection via Iroh
**if** Biscuit capability auth is enforced on Iroh connections (rbac-design.md Phase 2).
This is a prerequisite dependency.

### 6. Incremental Encrypted Sends Have a Constraint

`btrfs receive` requires a plaintext parent subvolume on the receiving node. Encrypted
parents in Iroh cannot serve as incremental send parents directly [H4 §Findings].
Workaround: store plaintext snapshots locally (protected by OS-level access control),
encrypt only for transfer/archival. For fully untrusted cross-node transfer, fall back
to full (non-incremental) encrypted sends.

## Analysis

### Convergent Findings

All five hypotheses converge on the same architecture:

1. **Encrypt at the snapshot boundary** (not at runtime) — H1, H3, H4 all agree
2. **Envelope encryption** (symmetric DEK + asymmetric key wrapping) — H1, H2, H4 all use this pattern
3. **Client-side keys are essential** — H1 (Iroh injection), H2 (PRE), H5 (FOKS wallet)
4. **Server acts as a proxy, not a trust anchor** — H2 (PRE), H3 (tier model), H5 (FOKS)

### Contradictions

**H1 vs H3 on "zero-knowledge"**: H1's Option 3a (server-transient DEK) provides
encrypted-at-rest but trusts the server during boot. H3 says this is honest-but-curious
only, not true ZK. Resolution: **both are right**. Option 3a is the pragmatic first step;
true ZK requires H3's Tier 3 (confidential computing + virtio-blk). The tier model
acknowledges this is a spectrum, not binary.

**H4 on "AES-512"**: The user mentioned AES-512 as minimum. H4 conclusively shows
Rijndael-512 is impractical (no implementations, no HW accel, no quantum benefit over
AES-256). Resolution: XChaCha20-Poly1305 with 256-bit keys provides equivalent or
better security with 6x+ better performance. The "512" concern is addressed by the
overall system: XChaCha20 (256-bit key) + ML-KEM (post-quantum key exchange) + Blake3
(256-bit hash) = a fully post-quantum-resistant stack without needing Rijndael-512.

### Gaps

1. **Recrypt maturity**: Recrypt is Phase 1 of 8 in implementation [H2 §Open Questions].
   Mjolnir may need a simpler PRE implementation initially.

2. **FOKS-Recrypt crypto compatibility**: FOKS uses Curve25519 + ML-KEM. Recrypt uses
   OpenFHE BFVrns. These are different post-quantum schemes. Can they share a key
   hierarchy? [H5 §Open Questions]

3. **Guest-side FOKS verification**: The guest agent (Rust) needs to verify FOKS
   signature chains. No Rust FOKS client exists — would need to be built or the
   Go client called via subprocess.

4. **Encrypted overlay UX**: H1's Option 3c (encrypted overlay) is the best balance
   for runtime protection without confidential computing. But the guest-side
   implementation (LUKS mount after Iroh DEK injection) needs detailed design.

## Recommendation

### The Complete Stack

```
┌─────────────────────────────────────────────────────┐
│                    User's Device                     │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │ Identikey│  │   FOKS   │  │   mjolnir CLI      │ │
│  │  (OIDC)  │  │  (keys)  │  │  (Biscuit + DEK)   │ │
│  └────┬─────┘  └────┬─────┘  └────────┬───────────┘ │
│       │identity     │PUK/PTK          │              │
└───────┼─────────────┼─────────────────┼──────────────┘
        │             │                 │
        ▼             ▼                 │
┌───────────────────────────────────────┼──────────────┐
│              Mjolnir Server           │              │
│  ┌──────────┐  ┌──────────┐           │              │
│  │  Biscuit │  │ Recrypt  │           │              │
│  │  verify  │  │  proxy   │           │              │
│  └──────────┘  └──────────┘           │              │
│  ┌──────────────────────────┐         │              │
│  │ BTRFS + btrfs send/recv  │         │              │
│  │ XChaCha20 encrypted blobs│         │              │
│  └──────────────────────────┘         │              │
│  ┌──────────────────────────┐         │              │
│  │    Iroh blob storage     │◄────────┘ DEK inject   │
│  │  (content-addressed)     │   via Iroh direct      │
│  └──────────────────────────┘                        │
│  Server sees: encrypted blobs, wrapped DEKs,         │
│  Biscuit tokens. Never sees: plaintext DEK,          │
│  snapshot contents, user data.                       │
└──────────────────────────────────────────────────────┘
```

### Build Phases (Revised from Pre-Research Plan)

#### Phase 0: Storage Foundation (1-2 weeks) — BUILD NOW

No change from the pre-research plan. These are prerequisites for everything:

1. Split dormant registry to per-VM files
2. Add `version` fields to all metadata JSON
3. Reserve `encryption` and `distribution` fields
4. Add `btrfs send/receive` support to `Mjolnir.BTRFS`

#### Phase 1: Encrypted Snapshots at Rest (2-3 weeks) — BUILD NEXT

**Changed from pre-research plan**: Use XChaCha20 (not AES-256-GCM), use libsodium
secretstream for chunked AEAD, and design the DEK wrapping to be FOKS-compatible
even before FOKS is integrated.

1. `Mjolnir.Crypto` module — XChaCha20-Poly1305 secretstream, envelope encryption
2. DEK generation per-snapshot, wrapped with user's public key
3. `btrfs send | zstd | secretstream-encrypt | store` pipeline
4. Snapshot metadata with `encryption` field (wrapped_dek, algorithm, key_id)
5. Server-transient DEK model (Option 3a) for boot — client sends DEK in spawn API

#### Phase 2: FOKS Integration + Biscuit Auth on Iroh (3-4 weeks)

**New phase** (not in pre-research plan):

1. Run FOKS server as sidecar to Mjolnir
2. Bridge Identikey OIDC → FOKS identity (public key registration)
3. Replace server-derived KEKs with FOKS PUKs for DEK wrapping
4. Add `KEY_INJECT` ALPN to guest Iroh endpoint
5. Implement Biscuit auth on Iroh connections (rbac-design.md Phase 2)
6. Client injects DEK via Iroh instead of API call

#### Phase 3: Proxy Re-encryption Sharing (2-3 weeks)

1. Integrate Recrypt for wrapped DEK re-encryption
2. `access_grants` in snapshot metadata with re-encrypted wrapped DEKs
3. `mjolnir snap share` CLI command
4. Extend Biscuit policy layer for access_grants authorization
5. Team sharing via FOKS PTKs (team key wrapping)

#### Phase 4: Encrypted Overlay for Runtime Protection (2-3 weeks)

H1's Option 3c — best balance without confidential computing:

1. Generic unencrypted base OS boots normally via virtio-fs
2. User data partition as LUKS volume file on virtio-fs mount
3. Guest agent receives DEK via Iroh, mounts encrypted overlay
4. Server sees encrypted block file but not contents, even during runtime

#### Phase 5: Distributed Snapshots via Iroh (3-4 weeks)

Same as pre-research plan but with encryption built in:

1. `mjolnir-distributor` Rust sidecar (host-side Iroh endpoint)
2. Encrypted blob push/pull across nodes
3. FOKS federated key discovery for cross-node DEK resolution
4. Snapshot metadata gossip

#### Phase 6: Confidential Computing (Future — when CH SEV-SNP matures)

1. SEV-SNP or TDX for runtime memory protection
2. Remote attestation for DEK injection (client verifies guest is genuine)
3. Evaluate virtio-blk + dm-crypt vs hybrid (virtio-fs boot + virtio-blk data)
4. Full zero-knowledge runtime

### Decisions That Lock In Now

1. **XChaCha20-Poly1305 via secretstream** — Cipher choice. Aligns with Recrypt stack,
   eliminates nonce management, post-quantum when combined with ML-KEM key exchange.

2. **FOKS for key management** — Avoids building a custom key wallet. The key hierarchy
   (device → PUK → PTK) and federated protocol are exactly what's needed.

3. **Per-VM DEK** (not per-user) — Strictly more flexible. Per-user can be recovered
   (same DEK for all VMs) but not vice versa.

4. **Envelope encryption** — Symmetric DEK for bulk data, asymmetric wrapping for DEK.
   PRE operates on the wrapped DEK only. This pattern is locked in.

5. **btrfs send as serialization format** — Native, streaming, pipe-compatible.
   Encrypt the stream, not individual files.

## Open Questions

1. **Recrypt vs ML-KEM alignment**: Can Recrypt adopt ML-KEM to share FOKS's key hierarchy?
   Or does the user need separate keys for FOKS (identity) and Recrypt (re-encryption)?

2. **Encrypted overlay performance**: What's the I/O overhead of LUKS on a virtio-fs-backed
   file? Needs benchmarking on the target server.

3. **FOKS Go ↔ Mjolnir Elixir/Rust integration**: Run as sidecar (simplest) or port
   key primitives to Rust (better performance, more effort)?

4. **Incremental encrypted cross-node sends**: The workaround (decrypt parent to temp subvol)
   adds latency. Is full send acceptable for cross-node, with incremental only for local?

## References

[H1] hypotheses/h1-encrypted-snapshots-iroh-key/findings.md — Iroh DEK injection, boot-time options
[H2] hypotheses/h2-proxy-reencryption-sharing/findings.md — PRE + Biscuit composition
[H3] hypotheses/h3-confidential-computing/findings.md — SEV-SNP/TDX feasibility, tier model
[H4] hypotheses/h4-btrfs-send-encryption/findings.md — XChaCha20 benchmarks, streaming AEAD
[H5] hypotheses/h5-client-key-wallet-oidc/findings.md — FOKS integration, OIDC bridge

## Verification

- All 5 hypotheses produced findings with evidence [verified]
- No hypothesis was silently dropped [verified — H1-H5 all represented]
- Cipher performance claims grounded in published benchmarks [H4 §Data]
- Architectural constraints verified against codebase source locations [H1, H3 §Sources]
- FOKS capabilities verified against official documentation [H5 §Sources]
- Unsupported claim flagged: "AES-512 is minimum" — contradicted by evidence [H4]; resolved
  by demonstrating the full stack provides equivalent post-quantum security without Rijndael-512
