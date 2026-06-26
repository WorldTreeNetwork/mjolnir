# Encryption & Security Architecture

Mjolnir's security model is built around a single organizing principle: **data is classified into tiers by sensitivity, and each tier gets the strongest protection that preserves the storage features it needs.** This avoids the false choice between "encrypt everything" (losing BTRFS superpowers) and "encrypt nothing" (trusting the host with all data).

The result is a defense-in-depth architecture with four encryption layers, a cryptographically verified boot chain, and a three-tier storage model where the host never sees plaintext keys and cannot tamper with the base OS without detection.

## Three-Tier Storage Model

Every piece of data in a Mjolnir VM belongs to exactly one tier. The tiers are defined by who can read the data and what filesystem features are available.

```
┌─────────────────────────────────────────────────────────┐
│  Tier 1: BASE OS                                        │
│  BTRFS subvolume via virtio-fs · read-only              │
│                                                         │
│  Shared across all VMs via reflink clones.              │
│  Immutable — versioned by Blake3 manifest signature.    │
│  Verified at boot before any user code runs.            │
│                                                         │
│  Host can read: yes (but contents are immutable and     │
│  publicly known — the Ubuntu base image is not secret)  │
│  BTRFS features: full (dedup, compression, cloning)     │
├─────────────────────────────────────────────────────────┤
│  Tier 2: SEMI-PRIVATE USERLAND                          │
│  BTRFS subvolume via virtio-fs · read-write             │
│                                                         │
│  Per-VM writable space for application code, configs,   │
│  logs, packages, temp files. The "normal Linux box"     │
│  experience — most user data lives here.                │
│                                                         │
│  Host can read: yes (user trusts the hypervisor for     │
│  this tier, accepting visibility for BTRFS benefits)    │
│  BTRFS features: full (dedup, compression, snapshots,   │
│  incremental sync, instant cloning)                     │
├─────────────────────────────────────────────────────────┤
│  Tier 3: ENCRYPTED SECURE DATA                          │
│  LUKS2 image via virtio-blk · read-write                │
│                                                         │
│  Per-VM encrypted partition for secrets, credentials,   │
│  PII, and sensitive application data. Mounted at        │
│  /data/secure inside the guest.                         │
│                                                         │
│  Host can read: NO — sees only AES-XTS ciphertext.      │
│  Cannot decrypt even with root access to the server.    │
│  Key injected at boot from Identikey via Iroh.          │
│  BTRFS features: partial (reflink on .img file,         │
│  block-level incremental sync, but no cross-VM dedup    │
│  or compression — encrypted data is high-entropy)       │
└─────────────────────────────────────────────────────────┘
```

### Why Three Tiers?

Encrypting everything sounds safer but destroys the properties that make Mjolnir fast:

1. **BTRFS feature loss** — Encrypted data cannot be deduplicated across VMs, cannot be compressed (high entropy), and incremental sync operates at opaque block granularity rather than semantic file-level diffs.

2. **virtio-fs DAX transparency** — Even if you LUKS-encrypt via loopback inside the guest over virtio-fs, the decrypted data is visible to the host through virtiofsd's shared memory region (DAX). A host with root access can read the memory-mapped pages. Tier 3's virtio-blk path avoids this — dm-crypt operates inside the guest kernel and cleartext never leaves the guest's address space.

3. **Most data doesn't need encryption** — Application code, installed packages, and log files are not secrets. Paying the performance and feature cost of encryption for non-sensitive data is waste. Only genuinely sensitive data (credentials, PII, keys) belongs in Tier 3.

### BTRFS Feature Matrix

| Feature | Tier 1: Base OS | Tier 2: Semi-Private | Tier 3: Encrypted |
|---------|----------------|---------------------|-------------------|
| Reflink clone | Yes (shared base) | Yes (per-VM CoW) | Yes (CoW on .img file) |
| Incremental send | Send once, all share | Full file-level diffs | Block-level diffs (4KB) |
| Cross-VM dedup | Perfect (shared extents) | Yes (identical files) | No (different keys) |
| Transparent compression | Yes (zstd) | Yes (zstd) | No (high entropy) |
| Snapshot | Atomic with VM subvolume | Atomic with VM subvolume | Atomic with VM subvolume |
| Host can read | Yes (immutable, public) | Yes (by design) | No (ciphertext only) |

---

## Chain of Trust

Security starts at boot. Every component in the boot chain is verified before it runs.

```
Cloud Hypervisor (trusted — owns the hardware)
  │
  ├── loads vmlinux-ch         (PVH kernel, signed)
  └── loads initramfs.img      (cpio archive, signed)
        │
        initramfs /init:
        │
        ├── 1. Mount devtmpfs, start boot agent (vsock PTY)
        ├── 2. Mount virtio-fs "myfs" (base OS, read-only)
        ├── 3. Verify Blake3 manifest against signed hash
        │      └── Signature: ED25519 + ML-DSA-87 (dual classical + PQ)
        │      └── FAIL → emergency shell, refuse to boot
        ├── 4. Receive LUKS DEK via Iroh (E2E encrypted, bypasses host)
        ├── 5. Open LUKS partition, shred key material
        ├── 6. Assemble merged rootfs (overlay: base + userland + secure)
        └── 7. switch_root → systemd → full guest agent
```

The initramfs is the **trust root**. It runs before any unverified code and contains the public keys needed to verify everything else. A malicious host would have to replace both the initramfs AND its signature, which requires the private signing key.

> **Current status (Phase A):** The initramfs boot chain is implemented and working. The boot agent starts, virtiofs mounts, switch_root pivots to the real rootfs. Blake3 verification (step 3) and LUKS key injection (step 4) are designed but not yet implemented — they are the next implementation targets. See `docs/plans/initramfs-verified-boot.md` for the full boot sequence specification.

---

## Four Encryption Layers

Mjolnir provides defense-in-depth through four independent encryption layers. Each layer addresses a specific threat using the technology best suited for it. No single layer's compromise breaks the others.

### Layer 1: Transport Encryption

**Threat:** Network eavesdropping, man-in-the-middle attacks.

**Technology:** Iroh QUIC + TLS 1.3. End-to-end encrypted connections established directly between the user's device and the guest's Iroh endpoint. The host cannot read traffic even though it transits the host's network stack.

**Protects:** Key injection (LUKS DEK delivery), PTY console traffic, inter-VM communication, Recrypt payload delivery.

**Host sees:** Encrypted QUIC packets. Cannot decrypt without TLS session keys, which exist only in endpoint memory.

### Layer 2: Key Transformation (Proxy Re-Encryption)

**Threat:** Unauthorized cross-boundary data access. User A's data needs to be accessible to VM B without sharing private keys, and without the proxy learning the plaintext.

**Technology:** OpenFHE BFV lattice-based PRE. A re-encryption key `rk(A→B)` transforms ciphertext from A's public key to B's public key. The proxy performs the transformation on ciphertext without seeing plaintext or either party's private key.

**Protects:** Cross-user data sharing, snapshot access delegation, LUKS DEK wrapping for VM spawn. The DEK for a VM's LUKS partition is encrypted under the user's public key. At spawn time, the proxy re-encrypts it under the VM's ephemeral key.

**Host sees:** BFV lattice ciphertexts (~5-10KB opaque blobs). Cannot extract the DEK or private keys. The re-encryption key allows only the specific directional transformation.

> **Current status:** Designed. Implementation deferred to Phase 3 of the build plan. See `docs/research/zero-knowledge-vm-storage/synthesis.md` for the research that selected this approach.

### Layer 3: At-Rest Encryption (LUKS2 / dm-crypt)

**Threat:** Host reading sensitive data from storage at rest — disk inspection, backup theft, decommissioned hardware.

**Technology:** LUKS2 with `aes-xts-plain64` (512-bit keys, 256-bit effective), hardware-accelerated via AES-NI. The encrypted partition is presented to the VM as a virtio-blk device. dm-crypt operates directly on the block device with no loopback indirection.

| Parameter | Value |
|-----------|-------|
| Format | LUKS2 |
| Cipher | aes-xts-plain64 |
| Key size | 512-bit (256-bit effective, XTS uses twin keys) |
| PBKDF | Argon2id (passphrase mode) or raw key (DEK injection mode) |

**Protects:** Tier 3 data — secrets, credentials, PII, sensitive application data. Everything written to `/data/secure/` is transparently encrypted before reaching host storage.

**Does NOT protect:** Tier 2 data. Files on the virtio-fs share are plaintext on the host's BTRFS. This is by design — see "Why Three Tiers?" above.

**Host sees:** The `data.img` file on BTRFS contains only ciphertext. The LUKS header is visible (cipher metadata, key slots) but the DEK is protected by the injection flow.

> **Current status:** Implemented for the secrets volume (passphrase injection via Iroh). See `docs/secrets-architecture.md` for the full secrets protocol. Raw DEK injection (for verified boot) is designed but not yet implemented.

### Layer 4: Integrity Verification (Blake3 + Signed Boot)

**Threat:** A malicious host tampering with the base OS to inject backdoors that exfiltrate injected keys. Example: host modifies `/sbin/init` to phone home the LUKS DEK after injection.

**Technology:** Blake3 cryptographic hashing over a file manifest, signed with ED25519 + ML-DSA-87 (dual classical + post-quantum). The initramfs verifies the manifest before pivoting to the base OS.

**Protects:** Tier 1 integrity. If any file in the base OS has been modified, the boot is refused and the VM drops to an emergency shell.

**Host cannot:** Modify base OS files without detection, as long as the initramfs and its embedded public keys are genuine.

> **Current status:** Designed. The initramfs trust root is in place (Phase A complete). Blake3 verification logic is the next implementation target. See `docs/plans/initramfs-verified-boot.md` §"Blake3 Manifest Verification" for the build-time and boot-time verification flows.

### Layer Summary

```
Secure payload (incoming):

  User Device ──Iroh QUIC TLS 1.3──→ Guest Iroh Endpoint
                                           │
       (Layer 1: transport encrypted)      │
                                           ▼
                                    Recrypt decrypt
                                    (Layer 2: PRE unwrap)
                                           │
                                           ▼
                                    Write to /data/secure/
                                    (Layer 3: LUKS dm-crypt)
                                           │
                                           ▼
                                    Host BTRFS: ciphertext only

  At no point does the host see cleartext.
  At no point does the host hold a decryption key.
```

```
Application data (semi-private):

  App writes to /app/code/server.js
       │
       ▼
  virtio-fs → virtiofsd → Host BTRFS: plaintext
  (Host CAN read — user accepts this for Tier 2)
  (Full BTRFS benefits: dedup, compression, sync)
```

---

## Secrets Management

Mjolnir provides encrypted secrets as environment variables — applications consume them like standard env-based configuration (`DATABASE_URL`, `API_KEY`). No Mjolnir-specific code required.

### How It Works

1. **Spawn** a VM with `secrets_mode: "persistent"`
2. **Authorize** your Iroh peer for injection (`POST /api/vms/:id/authorize-inject`)
3. **Inject** passphrase via direct Iroh QUIC connection (bypasses host entirely)
4. **Use** secrets — every `exec` command auto-sources the secrets env file

```
Client (laptop)                 Host (Elixir)              Guest (VM)
───────────────                 ─────────────              ──────────
Spawn VM ─────────────────────> POST /api/vms
                                │ boot agent ──────────────> agent starts
                                │                            Iroh ready
Authorize peer ───────────────> authorize-inject ──────────> add to allowlist
Inject passphrase ──────────────────────────────────────────> SECRET_INJECT_ALPN
  (direct Iroh QUIC)            (bypasses host)              │ verify peer
                                                             │ LUKS open/create
                                                             │ mount /secrets
                                                             │ load env vars
                                                             ✓ one-shot guard set
Use secrets ──────────────────> exec ──────────────────────> $DATABASE_URL available
```

### Security Properties

| Property | Mechanism |
|----------|-----------|
| Host never sees secrets in transit | Iroh QUIC bypasses vsock; E2E encrypted |
| Only authorized peers can inject | `AUTHORIZED_INJECT_PEERS` allowlist on guest |
| One-shot injection guard | Atomic `compare_exchange` — inject only once per session |
| Passphrase zeroed after use | `zeroize` crate wipes memory |
| Key file shredded from disk | Overwritten with zeros before deletion |
| Env key names validated | `[A-Za-z_][A-Za-z0-9_]*` regex prevents injection |
| Secrets survive snapshot | Rendered plaintext lives on tmpfs (`/run/mjolnir/secrets.env`) and is never captured by a BTRFS snapshot; only the LUKS file is on the rootfs, and it is ciphertext at rest |

> **Full protocol specification:** `docs/secrets-architecture.md`

---

## Cipher Suite

Each layer uses the algorithm best suited to its context. The full cipher suite:

| Function | Algorithm | Key Size | Why This Choice |
|----------|-----------|----------|-----------------|
| Manifest hash | Blake3 | 256-bit | 4-8x faster than SHA-256, used for integrity checking and content addressing |
| Boot signing | ED25519 + ML-DSA-87 | 256-bit + PQ | Dual classical + post-quantum. Both must verify. |
| LUKS at-rest | AES-256-XTS | 512-bit (256 effective) | dm-crypt standard, AES-NI accelerated (3-5 GB/s) |
| LUKS key derivation | Argon2id (passphrase) or raw key (DEK) | 256-bit | Argon2id for human passwords; raw key for automated injection |
| DEK wrapping (PRE) | OpenFHE BFV lattice | Post-quantum | PRE operates on wrapped key only (~256 bits) — milliseconds regardless of data size |
| Content encryption | XChaCha20-Poly1305 | 256-bit | AEAD with 192-bit nonces. Used by Recrypt for file-level encryption. |
| Key transport | Iroh QUIC + TLS 1.3 | Session keys | E2E encrypted, host cannot intercept |
| Content hashing | Blake3 | 256-bit | All application-level hashing, content addressing, Bao streaming verification |

### Why AES-XTS for LUKS (Not XChaCha20)

- **Kernel compatibility** — `cryptsetup` expects kernel crypto API names. `aes-xts-plain64` is universal. There is no `xchacha20-poly1305` dm-crypt cipher in mainline kernels.
- **Hardware acceleration** — AES-XTS with AES-NI: 3-5 GB/s. XChaCha20 in kernel (software): 1-2 GB/s.
- **Different layers, different ciphers** — LUKS encrypts blocks (AES-XTS is ideal). Recrypt encrypts streams (XChaCha20 is ideal). Each layer uses its best tool.

---

## Key Management (FOKS)

Key lifecycle management uses FOKS (Federated Open Key Service), a protocol designed by the Keybase co-founders.

```
Device keys → Per-User Keys (PUKs) → Per-Team Keys (PTKs)
```

- **Automatic cascading re-keying** on device revocation
- **Federated protocol** — each Mjolnir node can run a FOKS server
- **Signature chains + Merkle trees** prevent server tampering with key history
- **Post-quantum** — Curve25519 + ML-KEM
- **OIDC bridge** — Identikey OIDC identity maps to FOKS public key at first login

FOKS replaces the need for a custom key wallet. The DEK for each VM's LUKS partition is wrapped with the user's PUK. Cross-user sharing uses PRE to re-encrypt the wrapped DEK under the recipient's PUK — the server performs the transformation without seeing the plaintext key.

> **Current status:** Designed. Implementation planned for Phase 2. See `docs/research/zero-knowledge-vm-storage/synthesis.md` §"Phase 2: FOKS Integration" and `docs/research/zero-knowledge-vm-storage/hypotheses/h5-client-key-wallet-oidc/findings.md`.

---

## Threat Model

### What We Defend Against

| Threat | Mitigation | Layer |
|--------|-----------|-------|
| Host reads secrets at rest | LUKS2 encryption, host sees only ciphertext | Layer 3 |
| Host reads secrets in transit | Iroh QUIC bypasses host entirely | Layer 1 |
| Host tampers with base OS | Blake3 manifest verified at boot | Layer 4 |
| Host intercepts DEK injection | Iroh E2E encryption, no vsock path for keys | Layer 1 |
| Network eavesdropping | QUIC + TLS 1.3 on all Iroh traffic | Layer 1 |
| Unauthorized cross-user access | PRE re-encryption, Biscuit capability tokens | Layer 2 |
| Key compromise propagation | Per-VM DEK, FOKS cascading re-key on revocation | Key mgmt |
| Post-quantum cryptanalysis | ML-DSA-87 signatures, ML-KEM key exchange | Layers 2, 4 |
| Re-injection after compromise | Atomic one-shot guard, compare_exchange | Secrets |
| Passphrase in guest memory | Zeroized after use via `zeroize` crate | Secrets |

### What We Do NOT Defend Against (Yet)

| Threat | Status | Path Forward |
|--------|--------|-------------|
| Malicious host reading guest memory at runtime | Not defended | AMD SEV-SNP / Intel TDX (Phase 6, when CH support matures) |
| Host observing virtio-fs I/O patterns | Not defended | Tier 2 data is plaintext by design; Tier 3 uses virtio-blk |
| Compromised initramfs signing key | Trust assumption | Offline key management, HSM storage |
| Supply chain attack on kernel/busybox | Partial (SHA256 pinned busybox) | Reproducible builds, signed kernel |

---

## Design Principles

1. **The initramfs is the trust root.** It runs before any unverified code and contains the public keys to verify everything else.

2. **Go with the grain of Linux.** LUKS/dm-crypt is battle-tested, AES-NI accelerated, kernel-optimized. Don't reinvent block encryption.

3. **virtio-fs is the superpower.** Live filesystem sharing, reflink clones, instant snapshots, dedup, compression. Keep as much data on virtio-fs as possible. Only use the encrypted tier when data genuinely needs host-opaque encryption.

4. **Signing is versioning.** A Blake3 manifest hash uniquely identifies a base OS image. Signing that hash creates an immutable version record.

5. **The VM cannot start without cryptographic authorization.** The LUKS key is not on-disk. It arrives via Iroh from Identikey. No key, no boot.

6. **The host never sees plaintext keys.** All key material flows through E2E encrypted channels (Iroh QUIC) or proxy re-encryption (PRE transforms without decrypting).

7. **Each encryption layer does what it's best at.** LUKS encrypts the box. PRE controls who has the key. Iroh secures transport. Don't conflate them.

---

## Implementation Status

| Component | Status | Reference |
|-----------|--------|-----------|
| Initramfs boot chain | **Implemented** | Phase A complete — boot agent, switch_root, two-phase agent detection |
| Serial console logging | **Implemented** | Per-VM serial log for boot diagnostics |
| LUKS secrets volume | **Implemented** | Passphrase injection via Iroh, env var auto-source |
| Peer-authenticated injection | **Implemented** | `AUTHORIZED_INJECT_PEERS` allowlist |
| One-shot injection guard | **Implemented** | Atomic `compare_exchange` |
| Blake3 manifest verification | **Designed** | Next target — `docs/plans/initramfs-verified-boot.md` §"Blake3 Manifest Verification" |
| Raw DEK injection (vs passphrase) | **Designed** | Part of verified boot flow |
| Three-tier storage layout | **Designed** | Tier 1+2 via virtio-fs working; Tier 3 via virtio-blk designed |
| PRE / Recrypt integration | **Designed** | Phase 3 — `docs/research/zero-knowledge-vm-storage/synthesis.md` |
| FOKS key management | **Designed** | Phase 2 — requires FOKS server sidecar |
| Biscuit auth on Iroh | **Designed** | `docs/plans/rbac-design.md` Phase 2 |
| Confidential computing (SEV-SNP) | **Future** | Phase 6 — waiting for CH SEV-SNP maturity |

---

## Related Documents

- **`docs/plans/initramfs-verified-boot.md`** — Full verified boot design: boot sequence, Blake3 verification, cipher suite selection, three-tier storage definition
- **`docs/secrets-architecture.md`** — LUKS secrets implementation: inject protocol, storage layout, threat model, guest agent components
- **`docs/research/zero-knowledge-vm-storage/synthesis.md`** — Research synthesis: XChaCha20 selection, FOKS architecture, PRE evaluation, build phases
- **`docs/plans/rbac-design.md`** — Biscuit capability tokens and authorization model
- **`docs/research/zero-knowledge-vm-storage/hypotheses/`** — Individual research findings (H1-H6)
