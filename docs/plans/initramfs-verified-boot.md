# Initramfs Verified Boot Design

> **See also:** `docs/encryption-and-security.md` for the consolidated security architecture overview — three-tier storage model, four encryption layers, threat model, and implementation status.

Mjolnir's boot chain gains a cryptographic trust boundary by inserting an initramfs between kernel load and rootfs mount. The initramfs creates a verified, authenticated execution environment before any user data is accessible — enabling Blake3 integrity verification on the immutable base OS, LUKS-encrypted secure data unlocked via Identikey key injection, and a guest-owned PTY console from the first instruction.

## Motivation

The current boot flow has no verification step:

```
CH loads kernel → kernel mounts virtio-fs directly → userspace
```

The kernel trusts whatever virtio-fs serves. There is no point at which we can verify integrity, inject cryptographic keys, or gate boot on authentication. The initramfs fixes all three.

## Architecture: Three-Tier Storage

Mjolnir's storage model separates data into three tiers based on mutability, sensitivity, and the BTRFS features each tier can leverage.

```
Tier 1: BASE OS (BTRFS subvolume via virtio-fs, read-only)
  - Shared across VMs via reflink clones
  - Immutable, versioned by Blake3 manifest signature
  - Blake3 integrity verification at boot
  - Full BTRFS benefits: dedup, compression, instant cloning

Tier 2: SEMI-PRIVATE USERLAND (BTRFS subvolume via virtio-fs, read-write)
  - Per-VM writable space for application code, configs, logs, packages
  - Plaintext on host BTRFS — host can read (user trusts hypervisor for this tier)
  - Full BTRFS benefits: incremental sync, dedup, compression (zstd), snapshots
  - This is where most user data lives — the "normal Linux box" experience

Tier 3: ENCRYPTED SECURE DATA (LUKS2 image via virtio-blk)
  - Per-VM encrypted partition for secrets, credentials, PII, sensitive app data
  - Host sees only ciphertext — cannot read even with root access
  - Key injected at boot from Identikey via Iroh + optional PRE recryption
  - BTRFS block-level incremental sync works (4KB extent tracking)
  - No cross-VM dedup or compression (encrypted data is high-entropy)
```

### Design Principles

1. **The initramfs is the trust root.** It runs before any unverified code. It contains the public keys needed to verify everything else.
2. **Go with the grain of Linux.** LUKS/dm-crypt provides battle-tested, AES-NI accelerated, kernel-optimized transparent encryption. Don't reinvent it. Use virtio-blk for the encrypted partition so dm-crypt operates on a real block device — no loopback indirection.
3. **virtio-fs is the superpower.** Live filesystem sharing, reflink clones, instant snapshots, incremental sync, dedup, compression. Keep as much data on virtio-fs as possible. Only move data to the encrypted tier when it genuinely needs host-opaque encryption.
4. **Signing is versioning.** A Blake3 manifest hash uniquely identifies a base OS image. Signing that hash with a timestamped signature creates an immutable version record.
5. **The VM cannot start without cryptographic authorization.** The LUKS key is not on-disk. It arrives via Iroh from Identikey (or the recryption proxy). No key, no boot.
6. **The host never sees plaintext keys.** All key material flows through end-to-end encrypted channels (Iroh QUIC) or proxy recryption (PRE transforms without decrypting).
7. **Each encryption layer does what it's best at.** LUKS encrypts the box. Recrypt/PRE controls who has the key. Iroh secures transport. Don't conflate them.

### BTRFS Feature Matrix by Tier

| Feature | Tier 1: Base OS | Tier 2: Semi-Private | Tier 3: Encrypted |
|---------|----------------|---------------------|-------------------|
| Reflink clone | Yes (shared base) | Yes (per-VM CoW) | Yes (CoW on .img file) |
| Incremental send | Send once, all share | Full file-level diffs | Block-level diffs (4KB) |
| Cross-VM dedup | Perfect (shared extents) | Yes (identical files) | No (different keys → different ciphertext) |
| Transparent compression | Yes (zstd) | Yes (zstd) | No (high entropy) |
| Snapshot | Atomic with VM subvolume | Atomic with VM subvolume | Atomic with VM subvolume |
| Host can read | Yes (immutable, doesn't matter) | Yes (by design) | No (ciphertext only) |

## Encryption Layers & Host Isolation

Mjolnir provides defense-in-depth through four independent encryption layers. Each layer addresses a specific threat and uses the technology best suited for it.

### Layer 1: Transport Encryption (Iroh QUIC + TLS 1.3)

**Threat**: Network eavesdropping, man-in-the-middle attacks.

**Technology**: Iroh provides end-to-end encrypted QUIC connections using TLS 1.3 session keys. The host cannot read traffic even though it transits the host's network stack, because the TLS session is established directly between the user's device and the guest's Iroh endpoint.

**What it protects**: Key injection (LUKS DEK delivery), Recrypt payload delivery, PTY console traffic, all inter-node communication.

**Host sees**: Encrypted QUIC packets. Cannot decrypt without the TLS session keys, which exist only in the endpoints' memory.

### Layer 2: Key Transformation (Recrypt / Proxy Re-Encryption)

**Threat**: Unauthorized access to data across trust boundaries. Data encrypted under User A's key needs to be accessible to VM B without A sharing their private key, and without the proxy learning the plaintext.

**Technology**: OpenFHE BFV lattice-based PRE. A re-encryption key `rk(A→B)` transforms ciphertext encrypted under A's public key into ciphertext decryptable by B's private key. The proxy (host) performs the transformation on the ciphertext without ever seeing the plaintext or either party's private key.

**What it protects**: Cross-user data sharing, snapshot access delegation, LUKS key wrapping for VM spawn. The DEK (Data Encryption Key) for a VM's LUKS partition is encrypted under the user's public key. At spawn time, the proxy re-encrypts it under the VM's ephemeral public key. The VM decrypts with its private key (injected via Iroh).

**Host sees**: BFV lattice ciphertexts (~5-10KB opaque blobs). Cannot extract the plaintext DEK or either party's private key. The re-encryption key `rk(A→B)` allows *only* the specific directional transformation — it cannot be used to decrypt directly.

### Layer 3: At-Rest Encryption (LUKS2 / dm-crypt via virtio-blk)

**Threat**: Host reading sensitive data from the VM's storage at rest (disk inspection, backup theft, decommissioned hardware).

**Technology**: LUKS2 with `aes-xts-plain64` (512-bit keys, 256-bit effective), hardware-accelerated via AES-NI. The encrypted partition is presented to the VM as a virtio-blk device (`/dev/vda`). dm-crypt operates directly on the block device — no loopback indirection, no FUSE stacking.

**What it protects**: Tier 3 (Encrypted Secure Data) — secrets, credentials, PII, sensitive application data. Everything written to `/data/secure/` is transparently encrypted by the kernel before reaching the host's storage.

**Host sees**: The `data.img` file on BTRFS contains only ciphertext. AES-XTS encrypts each 512-byte sector independently, so even the access pattern (which sectors were written) is visible, but the content is not. The LUKS header is visible (contains cipher metadata, key slots) but the DEK is protected by the key injection flow.

**What it does NOT protect**: Tier 2 (Semi-Private Userland). Files on the virtio-fs share are plaintext on the host's BTRFS. This is by design — the user accepts host visibility for general data in exchange for full BTRFS features (dedup, compression, incremental sync). Only genuinely sensitive data belongs in Tier 3.

**Why not encrypt everything?** Two reasons:
1. **BTRFS feature loss**: Encrypted data cannot be deduplicated across VMs, cannot be compressed, and incremental sync operates at opaque block granularity rather than semantic file-level diffs.
2. **virtio-fs DAX transparency**: Even if you LUKS-encrypt via loopback inside the guest over virtio-fs, the decrypted data would be visible to the host through virtiofsd's shared memory region (DAX). A malicious host with root access can read the virtiofsd process's memory-mapped pages. Tier 3's virtio-blk path avoids this entirely — dm-crypt operates inside the guest kernel, and the cleartext never leaves the guest's address space.

### Layer 4: Integrity Verification (Blake3 Manifest + Signed Boot Chain)

**Threat**: A malicious host tampering with the base OS to inject backdoors that exfiltrate injected keys. Example: host modifies `/sbin/init` to phone home the LUKS DEK after injection.

**Technology**: Blake3 cryptographic hashing over a file manifest, signed with ED25519 + ML-DSA-87 (dual classical + post-quantum). The initramfs (which is itself signed and loaded by Cloud Hypervisor) verifies the base OS manifest before pivoting to it.

**What it protects**: Tier 1 (Base OS) integrity. The initramfs walks the base OS filesystem, computes Blake3 hashes, and compares against a signed manifest. If any file has been modified, the boot is refused and the VM drops to an emergency shell.

**Host cannot**: Modify base OS files without detection, as long as the initramfs and its embedded public keys are genuine. The initramfs is a signed artifact loaded directly by Cloud Hypervisor — the host would have to replace both the initramfs AND the signature, which requires the private signing key.

### Layer Summary

```
Data Flow (incoming secure payload):

  User Device ──Iroh QUIC TLS 1.3──→ Guest Iroh Endpoint
       │                                    │
       │  (Layer 1: transport encrypted)    │
       │                                    ▼
       │                             Recrypt decrypt
       │                             (Layer 2: PRE unwrap)
       │                                    │
       │                                    ▼
       │                             Write to /data/secure/
       │                             (Layer 3: LUKS dm-crypt)
       │                                    │
       │                                    ▼
       │                             Host BTRFS: ciphertext
       │
  At no point does the host see cleartext.
  At no point does the host hold a decryption key.
```

```
Data Flow (semi-private application data):

  Application writes to /app/code/server.js
       │
       ▼
  virtio-fs → virtiofsd → Host BTRFS: plaintext
  (Host CAN read this — user accepts this for Tier 2)
  (Full BTRFS benefits: dedup, compression, incremental sync)
```

## Boot Sequence

```
Cloud Hypervisor loads:
  ├── vmlinux-ch          (PVH kernel, signed separately)
  └── initramfs.img       (cpio archive, signed separately)

initramfs /init:
  1. Start mjolnir-boot-agent (vsock PTY + Iroh endpoint)
  2. Mount virtio-fs "myfs" at /mnt/host (read-only)
  3. Verify base OS Blake3 manifest:
     └── Read manifest from /mnt/host/os/.manifest.blake3
     └── Read signature from /mnt/host/os/.manifest.blake3.sig
     └── Verify MultiSig against pubkeys baked into initramfs
     └── Walk /mnt/host/os/, recompute Blake3 hashes
     └── Compare computed manifest hash against signed value
  4. Mount /mnt/host/os/ at /mnt/base (read-only bind mount)
  5. Start Iroh endpoint (using guest's pre-loaded Iroh key)
  6. Receive LUKS DEK via Iroh IdentiKey Inject protocol
     └── User device connects directly to guest (INJECT_ALPN, E2E encrypted)
     └── Delivers LUKS DEK (kind=2, symmetric-key, dest=luks:secure)
  7. Open LUKS: cryptsetup open /dev/vda secure \
       --type=luks2 --key-file=<decrypted_dek>
  8. Shred key material from tmpfs
  9. Set up merged root:
     └── Mount LUKS partition at /mnt/secure
     └── overlayfs: lower=/mnt/base upper=/mnt/host/user/root-overlay
         workdir=/mnt/host/user/overlay-work merged=/mnt/merged
     └── bind-mount /mnt/host/user/data → /mnt/merged/data
     └── bind-mount /mnt/secure → /mnt/merged/data/secure
  10. pivot_root /mnt/merged → exec /sbin/init
  11. Hand off vsock PTY from mjolnir-boot-agent → mjolnir-agent
```

## Blake3 Manifest Verification

Blake3 manifest verification replaces dm-verity for base OS integrity. This choice preserves virtio-fs as the sole storage backend for the base OS, avoiding the need for ext4 images or virtio-blk block devices for the OS layer.

### Why Not dm-verity?

dm-verity requires a block device — it intercepts block I/O and verifies each block against a Merkle hash tree. virtio-fs is a file-sharing protocol (FUSE-based), not a block device. Introducing dm-verity would require:
- Converting the base OS from a BTRFS subvolume to an ext4 block image
- Adding a virtio-blk device for the base OS
- Running both virtio-fs (for userdata) and virtio-blk (for base OS) simultaneously
- Losing BTRFS features (dedup, compression, reflink cloning) for the base OS layer

This complexity is not justified when Blake3 manifest verification provides equivalent tamper detection for Mjolnir's use case.

### How It Works

**Build time** (on the signing host):

```bash
# Walk the base OS subvolume, hash every file
find @base/ubuntu-24.04/ -type f -print0 | sort -z | while IFS= read -r -d '' f; do
  hash=$(b3sum --no-names "$f")
  printf '%s  %s\n' "$hash" "${f#@base/ubuntu-24.04/}"
done > manifest.txt

# Hash the manifest itself → single 32-byte root hash
b3sum --no-names manifest.txt > manifest.blake3

# Sign with dual classical + post-quantum
mjolnir-sign --key boot-signing.key \
  --input manifest.blake3 \
  --output manifest.blake3.sig

# Place into the base OS subvolume
cp manifest.txt manifest.blake3 manifest.blake3.sig \
  @base/ubuntu-24.04/.manifest.*
```

**Boot time** (in initramfs):

```bash
# 1. Verify signature on manifest hash
/bin/mjolnir-boot-agent --verify-sig \
  /mnt/host/os/.manifest.blake3.sig \
  /mnt/host/os/.manifest.blake3 \
  /etc/boot-verify.pub /etc/boot-verify-pq.pub
[ $? -ne 0 ] && echo "[!] SIGNATURE VERIFICATION FAILED" && exec /bin/sh

# 2. Re-walk filesystem, recompute hashes, compare
/bin/mjolnir-boot-agent --verify-manifest /mnt/host/os/
[ $? -ne 0 ] && echo "[!] MANIFEST MISMATCH — base OS tampered" && exec /bin/sh

echo "[+] Base OS integrity verified"
```

### Trade-offs vs dm-verity

| Aspect | Blake3 Manifest | dm-verity |
|--------|----------------|-----------|
| Verification timing | Eager (full hash at boot) | Lazy (hash on each read) |
| Boot cost | ~200ms for 1GB base (Blake3 at 5+ GB/s) | ~50ms setup, then per-read overhead |
| Runtime re-verification | No (read-only mount sufficient) | Yes (every block read) |
| Storage backend | Any filesystem (virtio-fs, NFS, etc.) | Block device only (virtio-blk) |
| BTRFS compatibility | Full (stays on BTRFS subvolume) | None (requires ext4 image) |
| Implementation complexity | ~100 lines Rust (hash + compare) | Kernel modules + veritysetup + ext4 tooling |
| Host tamper detection | At boot only (sufficient if read-only) | Continuous (detects post-boot tampering) |

The "no runtime re-verification" limitation is acceptable because the base OS is mounted **read-only** from a BTRFS snapshot via virtio-fs. Nothing in the guest can modify it. A post-boot host-side modification would require writing directly to the BTRFS subvolume while virtiofsd has it open — a narrow attack window that would likely corrupt the mount rather than cleanly substitute files.

### Optional: Spot-Check Mode

For faster boot on large base images, the initramfs can verify a subset of critical files rather than the full manifest:

```
Critical paths (always verified):
  /sbin/init, /lib/systemd/systemd
  /usr/bin/mjolnir-agent, /usr/bin/recrypt
  /etc/passwd, /etc/shadow, /etc/sudoers
  /lib/x86_64-linux-gnu/libc.so.6, libcrypto.so

Full manifest verification:
  Deferred to a background systemd service after boot
  Logs result, optionally halts if mismatch detected
```

This reduces boot-time verification to ~10ms (handful of files) while still catching the most impactful tampering. Full verification runs asynchronously after the VM is operational.

## Cipher Suite

### Chosen Algorithms

| Function | Algorithm | Exact Cipher String | Key Size | Rationale |
|----------|-----------|-------------------|----------|-----------|
| Blake3 manifest hash | Blake3 | N/A (userspace) | 256-bit | 4-8x faster than SHA-256, hardware-friendly. Used for all integrity checking: boot manifest, content addressing, Bao streaming verification. |
| Boot image signing | ED25519 + ML-DSA-87 | N/A (userspace) | 256-bit + PQ | Dual classical + post-quantum signatures. Matches `recrypt-core::sign::MultiSig`. Both must verify for the signature to be accepted. |
| LUKS bulk encryption | AES-256-XTS | `--cipher aes-xts-plain64 --key-size 512` | 512-bit (256 effective) | Matches existing secrets architecture (`docs/secrets-architecture.md`). AES-XTS is the Linux dm-crypt standard with hardware AES-NI acceleration. XTS mode uses two 256-bit keys (512 total) for tweakable encryption. |
| LUKS key derivation | None (raw key) | `--key-file` (not passphrase) | 256-bit | Unlike the existing secrets volume (which uses Argon2id PBKDF from a passphrase), the verified boot injects a raw 256-bit key. No PBKDF overhead. |
| DEK wrapping (PRE) | OpenFHE BFV lattice | N/A (userspace) | Post-quantum | 96-byte `KeyMaterial` bundle (32B sym key + 24B nonce + 32B plaintext hash + 8B size) is PRE-encrypted. ~5-10KB ciphertext. Recryption operates on wrapped key only — milliseconds regardless of data size. |
| Key transport | Iroh QUIC + TLS 1.3 | N/A (protocol) | Session keys | End-to-end encrypted channel bypassing the host. DEK ciphertext travels inside this tunnel. |
| Content encryption | XChaCha20-Poly1305 | N/A (userspace) | 256-bit | Used by Recrypt for file-level encryption of secure payloads. AEAD with 192-bit nonces (no nonce reuse risk). |
| Content hashing | Blake3 | N/A (userspace) | 256-bit | Used for all application-level hashing (file integrity, content addressing, Bao streaming verification). |

### Why AES-XTS for LUKS (Not XChaCha20)

The existing secrets architecture (`docs/secrets-architecture.md`) uses `aes-xts-plain64` with 512-bit keys. We retain this for LUKS because:

1. **dm-crypt cipher name compatibility** — `cryptsetup` expects kernel crypto API names. `aes-xts-plain64` is universally supported. There is no `xchacha20-poly1305` dm-crypt cipher name in mainline kernels.
2. **AES-NI hardware acceleration** — AES-XTS runs at ~3-5 GB/s on modern x86_64 with AES-NI. XChaCha20 (software-only in kernel) runs at ~1-2 GB/s. For block device encryption, this matters.
3. **Consistency** — Using the same LUKS cipher across both the secrets volume and secure data volume simplifies kernel config requirements.
4. **XChaCha20 remains the choice for streaming encryption** — The Recrypt stack uses XChaCha20-Poly1305 for file-level encryption (secure payloads, content-addressed blobs). Different layers use the best cipher for their context.

### Algorithm Substitutability

The design supports cipher agility at each layer:

- **Blake3 manifest**: Change hash function in `mjolnir-boot-agent --verify-manifest`. No kernel dependency.
- **Boot signing**: The initramfs signature format includes an algorithm identifier. New algorithms can be added without changing the verification flow.
- **LUKS**: `cryptsetup` supports pluggable ciphers. Switch via `--cipher` at format time.
- **DEK wrapping**: Recrypt's `PreBackend` trait abstracts over backends. Swap OpenFHE BFV for any future PRE scheme.

### Kernel Crypto Requirements

The guest kernel must have these options enabled:

```
# Storage
CONFIG_VIRTIO_FS=y             # virtio-fs (base OS + semi-private userland)
CONFIG_FUSE_FS=y               # FUSE support for virtiofsd
CONFIG_BLK_DEV_DM=y            # Device mapper (dm-crypt)
CONFIG_DM_CRYPT=y              # dm-crypt for LUKS

# Encryption
CONFIG_CRYPTO_XTS=y            # XTS block cipher mode
CONFIG_CRYPTO_AES=y            # AES cipher
CONFIG_CRYPTO_AES_NI_INTEL=y   # AES-NI hardware acceleration

# Filesystem
CONFIG_OVERLAY_FS=y            # overlayfs for merged root
```

## Ephemeral Key Derivation: Zero-Trust Key Injection

This is the critical security mechanism. The host must **never** see the plaintext LUKS DEK. The solution uses the user's device as the key authority, leveraging the existing Iroh `INJECT_ALPN` infrastructure.

### The Fundamental Constraint

PRE recryption keys are pair-specific: `RecryptKey` binds `(from_public, to_public)` (see `recrypt-core/src/pre/keys.rs:80-86`). You cannot create a wildcard recryption key for "any future VM." The VM's public key must exist before `generate_recrypt_key()` is called.

### Primary Path: User-Device-Generated Ephemeral Keypair (User Online)

The user's device generates the VM's ephemeral PRE keypair *before* requesting spawn. It sends the public key with the spawn request and injects the private key directly to the guest over Iroh after boot.

```
User Device                    Host                         Guest (initramfs)
─────────────                  ─────                        ─────────────────
1. vm_kp = generate_keypair()
2. rk = generate_recrypt_key(
     user_sk, vm_kp.public)
3. POST /spawn {
     vm_public_key,
     rk,                       4. Store rk + vm_pk
     biscuit, snap_id }           with VM metadata
                               5. Read wrapped_dek from
                                  snapshot metadata
                               6. Boot kernel + initramfs ──> /init starts
                                                              Blake3 verified
                                                              Iroh endpoint ready
                               7. authorize_inject_peer(     (via vsock configure)
                                    user_node_id)
                                                              Add user to
                                                              AUTHORIZED_INJECT_PEERS
8. Connect to guest via Iroh
   (INJECT_ALPN)
   Verify Blake3 manifest hash
   (optional remote attestation)
9. Send vm_kp.secret via Iroh ──────────────────────────────> 10. Receive vm_sk
   (E2E encrypted, bypasses host)                                 (one-shot injection guard)
                               11. rewrapped = recrypt(rk,
                                     wrapped_dek)
                               12. Deliver rewrapped ───────> 13. decrypt(vm_sk, rewrapped)
                                   via vsock                       → recover LUKS DEK
                                                              14. cryptsetup open /dev/vda
                                                              15. shred vm_sk + DEK
                                                              16. pivot_root, boot complete
```

**Security properties**:
- Host never sees `vm_sk` (delivered via Iroh E2E, not vsock)
- Host never sees plaintext DEK (only holds `rk` and `rewrapped_dek`, which are opaque BFV ciphertexts)
- The `rk` allows transforming ciphertexts from user→VM only — it cannot decrypt directly
- User retains control: can refuse to deliver `vm_sk` if the guest fails remote attestation
- One-shot injection guard (atomic `compare_exchange`) prevents replay

**Why this works**: The existing `INJECT_ALPN` infrastructure (`native/mjolnir_guest_agent/src/iroh.rs:145-155`) already handles E2E key delivery with peer authentication. The change is: instead of delivering a LUKS passphrase, deliver the VM ephemeral secret key. The LUKS unlock then uses the raw DEK (recovered via PRE decryption) rather than a passphrase + Argon2id.

### Intermediate Path: Direct DEK Delivery via Iroh (Phase C, Before PRE)

Before the full PRE integration, the user can unwrap the DEK locally and deliver it directly via Iroh. This is the simplest path for Phase C:

```
User Device                    Guest (initramfs)
─────────────                  ─────────────────
1. Unwrap DEK locally:
   dek = decrypt(user_sk,
     wrapped_dek)
2. Connect via Iroh
   (INJECT_ALPN)
3. Send raw DEK ──────────────> 4. Receive DEK
   (E2E encrypted)                 (one-shot guard)
                                5. cryptsetup open --key-file
                                6. shred DEK
                                7. pivot_root
```

This requires zero new crypto — just use the existing Iroh injection channel. The DEK exists in plaintext momentarily on the user's device (acceptable — it's the user's own data). The host never sees it.

### Offline Path: Pre-Committed Key Pool (Phase D+, User Offline)

For autonomous spawning (dormant VM restoration, scaling events), the user pre-generates a pool of ephemeral keypairs when online:

```
User Device (while online)     Host (later, autonomous)     Guest (initramfs)
─────────────────────────      ────────────────────────      ─────────────────
1. For i in 1..N:
     kp[i] = generate_keypair()
     rk[i] = generate_recrypt_key(
       user_sk, kp[i].public)
     sealed[i] = encrypt(
       kp[i].secret,
       sealing_key)
2. Upload pool:
   {rk[i], sealed[i], i}
   to host

(autonomous spawn later)
                               3. Allocate kp[j] from pool
                               4. rewrapped = recrypt(
                                    rk[j], wrapped_dek)
                               5. Boot, deliver sealed[j]
                                  + rewrapped via vsock ────> 6. Unseal vm_sk
                                                              7. decrypt(vm_sk, rewrapped)
                                                              8. cryptsetup open
                                                              9. pivot_root
```

**Sealing mechanism**: The sealed private keys are encrypted under a `sealing_key` that the host cannot derive:
- Option A: `sealing_key` baked into the initramfs (host could extract from the initramfs file — honest-but-curious safe, not cryptographically ZK)
- Option B: `sealing_key = HKDF(user_secret, roothash)` where `user_secret` is random 256-bit inside the sealed blob. Host cannot derive without `user_secret`.

**Trust trade-off**: The pre-committed pool is honest-but-curious safe (host would have to actively attack the initramfs), not cryptographically ZK. This is acceptable for autonomous spawning — the initramfs is a signed, auditable artifact. If someone modifies it to extract keys, the signature breaks.

### Optional: Remote Attestation via Blake3 Manifest Hash

Before delivering `vm_sk` (primary path, step 9), the user device can verify the guest booted the correct image:

1. User device requests Blake3 manifest hash from guest via Iroh
2. Boot agent reads the verified manifest hash from memory, reports it
3. User device compares against the expected hash from the signed manifest
4. Only delivers `vm_sk` if the hash matches

This is not hardware-backed attestation (no TPM/SEV-SNP), but it detects a tampered boot image as long as the guest is running the genuine initramfs (which is guaranteed by the signed boot chain, provided Cloud Hypervisor loaded the correct kernel+initramfs).

## IdentiKey Inject Protocol

Universal secret injection over Iroh QUIC. Replaces the previous `mjolnir-secret-inject/1` JSON protocol with a compact binary format using CBOR (RFC 8949) metadata with a formal CDDL schema (RFC 8610). Handles all secret injection use cases: boot key delivery, LUKS passphrases, environment variables, certificates, and arbitrary secret material.

Cryptographic key payloads use COSE_Key (RFC 9052 §7) serialization for standardized key type identification, algorithm binding, and interop.

### ALPN

```rust
pub const INJECT_ALPN: &[u8] = b"mjolnir/inject/1";
```

Both `mjolnir-boot-agent` (initramfs) and `mjolnir-agent` (full guest agent) register this ALPN. The `/1` denotes the wire format version.

### Wire Format

```
┌──────────┬────────────┬──────────────┬──────────────────┐
│ magic    │ meta_len   │ CBOR map     │ payload bytes    │
│ 2 bytes  │ 3 bytes BE │ (meta_len B) │ (until stream    │
│ 0x49 0x49│ 0 = none   │ (optional)   │  FIN)            │
│ "II"     │ max 16 MB  │              │                  │
└──────────┴────────────┴──────────────┴──────────────────┘

Response (from receiver):
┌──────────────────────────────────────────────────────┐
│ CBOR map (status)                                    │
└──────────────────────────────────────────────────────┘
```

- **Magic `0x49 0x49`** ("II" — IdentiKey Inject): Identifies the protocol. Receiver rejects immediately if magic doesn't match, preventing misrouted streams from being parsed as metadata lengths.
- **meta_len** (3 bytes, big-endian u24): Length of the CBOR metadata map. `0x00 0x00 0x00` = no metadata, apply all defaults. Max 16,777,215 bytes (~16 MB).
- **CBOR map**: Optional metadata conforming to the `inject-meta` CDDL schema (see below). Only present if meta_len > 0.
- **Payload**: Secret bytes, read until the QUIC stream FIN. The receiver never logs these bytes. For key payloads (kind=3), the payload is a CBOR-encoded COSE_Key.

Minimum overhead: 5 bytes (`49 49 00 00 00` + payload).

#### Encoding/Decoding (Rust)

```rust
// Encode meta_len as 3 bytes (u24 big-endian, stored in a u32)
let len_bytes = (meta_len as u32).to_be_bytes();
stream.write_all(&len_bytes[1..4]).await?;  // last 3 bytes of u32

// Decode
let mut buf = [0u8; 4];
stream.read_exact(&mut buf[1..4]).await?;   // read into last 3 bytes
let meta_len = u32::from_be_bytes(buf) as usize;
```

### CDDL Schema

The metadata and response are formally specified in CDDL (RFC 8610). This is the normative schema — the tables below are derived from it.

```cddl
; ============================================================
; IdentiKey Inject Protocol — Metadata & Response Schema
; Wire format: "II" (0x49 0x49) || meta_len (u24 BE) || meta (CBOR) || payload
; ============================================================

; --- Metadata (request) ---

inject-meta = {
  ? 1 => kind,              ; payload type (default: 0 = opaque)
  ? 2 => dest,              ; consumption directive (default: kind-dependent)
  ? 3 => bool,              ; once: one-shot injection guard (default: true)
  ? 4 => bool,              ; zeroize: scrub after consumption (default: true)
  ? 5 => uint,              ; ttl: auto-scrub seconds, 0 = disabled (default: 0)
  ? 6 => tstr,              ; label: human-readable name for logging
  ? 7 => bstr .size 32,     ; blake3: expected Blake3 hash of payload
  * int => any,             ; forward-compatible: unknown keys are ignored
}

kind = &(
  opaque:         0,        ; arbitrary secret bytes
  passphrase:     1,        ; UTF-8 passphrase string
  symmetric-key:  2,        ; raw symmetric key (e.g., 256-bit AES/XChaCha20)
  key:            3,        ; COSE_Key-encoded cryptographic key (see below)
  env:            4,        ; KEY=VALUE\n pairs (UTF-8)
  pem:            5,        ; PEM-encoded certificate/key bundle
  cbor:           6,        ; structured CBOR data (nested config)
)

dest = tstr                 ; "mem", "env", "luks:<name>", or "/path/..."

; --- Response ---

inject-response = {
  1 => bool,                ; ok: success or failure
  ? 2 => tstr,              ; error: message (only if ok = false)
  ? 3 => tstr,              ; dest: actual destination used
  ? 4 => bool,              ; created: new resource created (e.g., LUKS formatted)
  * int => any,             ; forward-compatible
}

; --- COSE_Key payload (when kind = 3) ---
; See RFC 9052 §7. The payload bytes are a CBOR-encoded COSE_Key map.

COSE_Key = {
  1 => kty,                 ; key type (required)
  ? 2 => bstr,              ; kid: key identifier
  ? 3 => int,               ; alg: algorithm restriction
  ? 4 => [+ key_ops],       ; key_ops: permitted operations
  * label => any,           ; key-type-specific parameters
}

kty = &(
  OKP:       1,             ; Edwards / Montgomery curves (Ed25519, X25519)
  EC2:       2,             ; NIST EC (P-256, P-384, P-521)
  symmetric: 4,             ; symmetric keys (HMAC, AES, ChaCha20)
  lattice:   -1,            ; lattice-based (OpenFHE BFV PRE) — private-use range
)

key_ops = &(
  sign:       1,
  verify:     2,
  encrypt:    3,
  decrypt:    4,
  wrap:       5,
  unwrap:     6,
  derive-key: 7,
  derive-bits:8,
  recrypt:   -1,            ; PRE recryption — private-use range
)

label = int / tstr
```

### Metadata Reference

All fields are optional. Omitted keys use defaults. An empty map (`0xA0`) or absent metadata (meta_len=0) means all defaults.

| CBOR Key | Name | CDDL Type | Default | Description |
|----------|------|-----------|---------|-------------|
| `1` | kind | uint (see `kind` choice) | `0` (opaque) | Nature of the payload bytes |
| `2` | dest | tstr | `nil` (kind-dependent) | Where to store or how to consume the payload |
| `3` | once | bool | `true` | One-shot: reject subsequent injections (atomic guard) |
| `4` | zeroize | bool | `true` | Scrub payload from memory after consumption |
| `5` | ttl | uint | `0` | Auto-scrub after N seconds (0 = no timer, scrub on use) |
| `6` | label | tstr | `nil` | Human-readable name for logs (payload is NEVER logged) |
| `7` | blake3 | bstr .size 32 | `nil` | Expected Blake3 hash of payload — verified before any use |

Unknown integer keys are ignored (forward-compatible extension point).

#### `kind` Values

| Value | Name | Payload Format | Default `dest` |
|-------|------|---------------|----------------|
| `0` | opaque | Arbitrary bytes | `mem` |
| `1` | passphrase | UTF-8 string | `luks:mjolnir-secrets` |
| `2` | symmetric-key | Raw key bytes | `mem` |
| `3` | key | COSE_Key (CBOR-encoded, see below) | `mem` (consumed in-memory, never written) |
| `4` | env | `KEY=VALUE\n` pairs (UTF-8) | `env` |
| `5` | pem | PEM-encoded bundle | `/run/mjolnir/secrets/<label>.pem` |
| `6` | cbor | Structured CBOR data | `mem` |

Unknown `kind` values are treated as `opaque`.

#### `dest` Conventions

| Pattern | Meaning | Example |
|---------|---------|---------|
| `nil` / absent | Kind-dependent default (see table above) | — |
| `luks:<name>` | Open LUKS device with this dm-crypt mapper name | `luks:secure`, `luks:mjolnir-secrets` |
| `env` | Load as environment variables | — |
| `/path/...` | Write to this path (tmpfs, mode 0600) | `/run/mjolnir/secrets/tls.pem` |
| `mem` | Hold in memory only, never touch disk | — |

### COSE_Key Payloads (kind=3)

When `kind=3` (key), the payload is a CBOR-encoded COSE_Key map (RFC 9052 §7). This provides standardized key type identification, algorithm binding, and interoperability with COSE-aware tooling — the same format used by WebAuthn/FIDO2 for attestation keys.

#### Why COSE_Key

- **Self-describing**: The key type (`kty`) and algorithm (`alg`) are encoded in the key itself, not inferred from context.
- **Algorithm agility**: Adding new key types (ML-KEM, X-Wing, future PQ algorithms) means adding a `kty` value, not changing the wire format.
- **IANA registry**: Standard `kty` values (OKP, EC2, symmetric) are IANA-registered. We extend into the private-use range for lattice PRE keys (`kty: -1`).
- **FIDO2 alignment**: The same serialization used for WebAuthn public key credentials.

#### Key Types Used in Mjolnir

**PRE Secret Key (boot key injection):**

```cbor
{
  1: -1,                    ; kty: lattice (private-use)
  2: h'<vm-uuid>',         ; kid: VM identifier
  3: -65537,               ; alg: OpenFHE-BFV-PRE (private-use)
  4: [4, 6],               ; key_ops: [decrypt, unwrap]
  -1: h'<serialized PRE SecretKey bytes>'  ; private key material
}
```

**Ed25519 Signing Key (if injecting signing capability):**

```cbor
{
  1: 1,                     ; kty: OKP
  3: -8,                    ; alg: EdDSA
  4: [1],                   ; key_ops: [sign]
  -1: 6,                    ; crv: Ed25519
  -4: h'<32-byte private key>'  ; d: private key
}
```

**Symmetric Key (raw LUKS DEK, alternative to kind=2):**

```cbor
{
  1: 4,                     ; kty: symmetric
  3: 24,                    ; alg: ChaCha20/Poly1305 (or -65536 for AES-XTS)
  4: [4],                   ; key_ops: [decrypt]
  -1: h'<32-byte key>'     ; k: key value
}
```

Using `kind=3` (COSE_Key) instead of `kind=2` (raw bytes) for symmetric keys is recommended when algorithm binding matters — the COSE_Key encodes *what cipher this key is for*, preventing a ChaCha20 key from being accidentally used with AES-XTS.

### Response

CBOR map with integer keys, conforming to `inject-response` schema:

| CBOR Key | Name | Type | Description |
|----------|------|------|-------------|
| `1` | ok | bool | Success or failure |
| `2` | error | tstr | Error message (only if ok = false) |
| `3` | dest | tstr | Actual destination used (echoed back) |
| `4` | created | bool | Whether a new resource was created (e.g., LUKS formatted) |

### Security Properties

| Property | Mechanism |
|----------|-----------|
| Confidentiality in transit | Iroh QUIC TLS 1.3 (E2E, host cannot read) |
| Peer authentication | `AUTHORIZED_INJECT_PEERS` allowlist (Iroh NodeId verification) |
| Replay prevention | `once: true` (default) — atomic compare_exchange guard |
| Payload integrity | Optional `blake3` field — verified before any use |
| Memory safety | `zeroize: true` (default) — payload scrubbed after consumption |
| Process isolation | Default `dest` is `mem` — payload never written to disk unless explicitly requested |
| No logging | Payload bytes are never logged. Only `label`, `kind`, and `dest` appear in logs |
| Time-bounded | Optional `ttl` — auto-scrub if not consumed within N seconds |
| Misroute protection | Magic bytes `0x49 0x49` — reject immediately if not present |
| Algorithm binding | COSE_Key payloads encode `kty` + `alg` — prevents key/cipher mismatch |

### Relationship to Existing Secret Inject Protocol

The IdentiKey Inject protocol replaces `mjolnir-secret-inject/1` (JSON-based, passphrase-specific). The mapping:

| Old (JSON) | New (II) |
|------------|----------|
| `{"action": "inject", "passphrase": "..."}` | kind=1 (passphrase), payload=passphrase bytes |
| `{"action": "status"}` | Not part of inject protocol (use vsock control channel) |
| `{"action": "set_env", "entries": {...}}` | kind=4 (env), payload=KEY=VALUE pairs |
| `{"action": "push_env", "content": "..."}` | kind=4 (env), payload=content bytes |
| `{"action": "close"}` | Not part of inject protocol (use vsock control channel) |

Status and lifecycle operations (`status`, `close`) move to the vsock JSON control channel where they belong — they are VM management operations, not secret injection.

## Storage Layout

### Host-Side (BTRFS filesystem)

```
/var/lib/mjolnir/
├── boot/                              # Signed boot artifacts
│   ├── vmlinux-ch                     # PVH kernel
│   ├── vmlinux-ch.sig                 # MultiSig over kernel hash
│   ├── initramfs.img                  # cpio archive (trust root)
│   └── initramfs.img.sig             # MultiSig over initramfs hash
│
├── @base/ubuntu-24.04/               # Tier 1: Base OS (read-only BTRFS snapshot)
│   ├── /sbin/init                    # Standard Ubuntu root filesystem
│   ├── /usr/...
│   ├── /etc/...
│   ├── .manifest.txt                 # Blake3 hash manifest (file → hash)
│   ├── .manifest.blake3              # Blake3 hash of manifest itself
│   └── .manifest.blake3.sig          # MultiSig over manifest hash
│
├── @vms/<uuid>/                       # Per-VM BTRFS subvolume
│   ├── os/                           # Tier 1: reflink clone of @base (read-only in guest)
│   ├── user/                         # Tier 2: semi-private userland (read-write via virtio-fs)
│   │   ├── data/                     # Application code, configs, logs
│   │   ├── root-overlay/             # overlayfs upper layer for system paths
│   │   └── overlay-work/            # overlayfs workdir
│   └── secure/                       # Tier 3: encrypted partition
│       └── data.img                  # LUKS2-encrypted block image (virtio-blk)
│
└── @snapshots/<name>/                 # Named snapshots (BTRFS CoW)
    ├── os/                           # Frozen base OS state
    ├── user/                         # Frozen semi-private userland
    ├── secure/
    │   └── data.img                  # Frozen encrypted data (ciphertext)
    └── metadata.json                 # Snapshot metadata: wrapped DEK, base OS version, etc.
```

### Guest-Side (After Boot)

```
/                    ← overlayfs merged root
├── /sbin/init       ← from Blake3-verified base (read-only lower)
├── /usr/...         ← from Blake3-verified base (read-only lower)
├── /etc/...         ← overlayfs: base /etc (lower) + user overlay (upper)
│                      Applications see a single merged /etc that is writable.
│                      Changes persist to the semi-private user tier.
│
/data/               ← bind mount from semi-private userland (Tier 2)
├── /data/home/
├── /data/app/       ← application code and state
├── /data/var/       ← logs, caches, runtime state
│
/data/secure/        ← LUKS-decrypted mount (Tier 3, virtio-blk)
├── /data/secure/secrets/    ← credentials, API keys, tokens
├── /data/secure/private/    ← PII, financial data, sensitive app data
└── /data/secure/keys/       ← cryptographic keys (injected via Identikey)
```

**Mount strategy**:
- System binaries (`/usr`, `/sbin`) come from the verified base — immutable
- Configuration (`/etc`) is an overlay — base provides defaults, user tier provides overrides
- General data (`/data`) is a direct bind mount from the semi-private user tier
- Secure data (`/data/secure`) is a mount from the LUKS-encrypted partition
- Applications do not need special path awareness — `/data/secure/` is just a directory

### Guest Agent Stack

```
/usr/bin/mjolnir-agent     # VM lifecycle, vsock, Iroh, PTY (from base OS)
/usr/bin/recrypt            # PRE operations: decrypt incoming payloads,
                            # encrypt outgoing payloads (from base OS)

Workflow for incoming secure data:
  1. Recrypt payload arrives via Iroh (PRE-encrypted under VM's public key)
  2. `recrypt decrypt` → recovers cleartext in memory
  3. Write to /data/secure/incoming/ → LUKS encrypts transparently
  4. Application reads /data/secure/incoming/ → LUKS decrypts transparently

Workflow for outgoing secure data:
  1. Application writes to /data/secure/outgoing/
  2. `recrypt encrypt --recipient=<target_pubkey>` → read + encrypt
  3. Send ciphertext via Iroh to target
```

## Cloud Hypervisor Configuration Changes

The VM needs both virtio-fs (for Tier 1 base OS and Tier 2 semi-private userland) and virtio-blk (for Tier 3 encrypted secure data partition).

### Config Struct Additions

```elixir
# lib/mjolnir/cloud_hypervisor/config.ex

typedstruct do
  # ... existing fields ...

  # New fields for verified boot
  field(:initramfs_path, String.t(), default: nil)
  field(:secure_data_image, String.t(), default: nil)   # LUKS2 data.img path for virtio-blk
end
```

### Payload Generation

```elixir
def kernel_payload(%__MODULE__{} = config) do
  base = %{
    "kernel" => config.kernel_path,
    "cmdline" => boot_args(config)
  }
  case config.initramfs_path do
    nil -> base
    path -> Map.put(base, "initramfs", path)
  end
end

defp boot_args(%__MODULE__{initramfs_path: nil} = config) do
  # Legacy mode: direct virtio-fs root mount
  config.boot_args
end

defp boot_args(%__MODULE__{} = config) do
  # Verified boot: initramfs handles mounting
  "console=ttyS0 reboot=k panic=1 " <>
    "mjolnir.vm_ip=#{config.network_interface[:guest_ip]} " <>
    "mjolnir.vm_cid=#{config.vsock_cid}"
end
```

### Disk Configuration (New)

```elixir
def disk_config(%__MODULE__{secure_data_image: nil}), do: nil

def disk_config(%__MODULE__{secure_data_image: path}) do
  [
    %{
      "path" => path,
      "readonly" => false
    }
  ]
end
```

### Updated vm_create_payload

```elixir
def vm_create_payload(%__MODULE__{} = config, vsock_path) do
  payload = %{
    "payload" => kernel_payload(config),
    "cpus" => cpus_config(config),
    "memory" => memory_config(config),
    "fs" => fs_config(config),
    "vsock" => vsock_config(config, vsock_path)
  }

  payload = case disk_config(config) do
    nil -> payload
    disks -> Map.put(payload, "disks", disks)
  end

  case network_config(config) do
    nil -> payload
    net -> Map.put(payload, "net", net)
  end
end
```

### virtiofsd Scope

virtiofsd continues to share the per-VM BTRFS subvolume, which now contains both `os/` (read-only base) and `user/` (semi-private userland). The `secure/` directory also lives in the subvolume but contains only the opaque `data.img` LUKS container — virtiofsd can see the file metadata but not the encrypted contents.

- **Current**: `shared_dir` = `@vms/<uuid>/` (full rootfs)
- **Verified boot**: `shared_dir` = `@vms/<uuid>/` (os/ + user/ + secure/data.img)

The initramfs mounts virtio-fs, verifies `os/` via Blake3, reads `user/` for overlay state, and the encrypted partition is accessed only via virtio-blk (`/dev/vda` pointing at `secure/data.img`).

## BTRFS Snapshot & Replication

### Snapshot Semantics

A single `btrfs subvolume snapshot` captures the entire VM state atomically:

```bash
btrfs subvolume snapshot @vms/<uuid>/ @snapshots/<name>/
```

This captures:
- `os/` — reflink of the shared base (nearly free, just metadata pointers)
- `user/` — CoW snapshot of semi-private userland (only changed blocks duplicated)
- `secure/data.img` — CoW snapshot of the encrypted partition (only changed 4KB extents)

All three tiers in one atomic operation. Restore is equally simple:

```bash
btrfs subvolume snapshot @snapshots/<name>/ @vms/<new-uuid>/
```

### Incremental Replication

BTRFS `send/receive` enables efficient replication across hosts:

```bash
# First snapshot: full send
btrfs send @snapshots/snap-v1/ | ssh remote btrfs receive /var/lib/mjolnir/@snapshots/

# Subsequent snapshots: incremental send (only changed data)
btrfs send -p @snapshots/snap-v1/ @snapshots/snap-v2/ | ssh remote btrfs receive /var/lib/mjolnir/@snapshots/
```

**Per-tier incremental efficiency:**

| Tier | Incremental Send Behavior | Typical Efficiency |
|------|--------------------------|-------------------|
| **os/** (base OS) | Near-zero if base version unchanged | Excellent — shared reflinks |
| **user/** (semi-private) | File-level diffs — only changed files sent | Excellent — semantic diffs |
| **secure/data.img** (encrypted) | Block-level diffs — changed 4KB extents of the .img | Good — AES-XTS encrypts sectors independently, so a small change only affects that sector's ciphertext extent |

The key insight for `data.img`: BTRFS tracks which 4KB extents of the file were written, regardless of whether the content is encrypted. `btrfs send` identifies exactly which extents changed between snapshots and sends only those. AES-XTS mode is sector-aligned — a change to one sector affects only that sector's ciphertext — so the incremental diff accurately reflects the *size* of the change, even though the *content* is opaque.

**What you cannot do** with the encrypted tier:
- **Cross-VM deduplication**: Same plaintext under different LUKS keys produces different ciphertext. Two VMs with identical files in their encrypted partitions will store two copies.
- **Transparent compression**: Encrypted data has high entropy and is incompressible. BTRFS zstd compression has no effect on `data.img`.
- **Content-aware diffing**: `btrfs send` knows *which blocks* changed but not *what* changed semantically. For the semi-private tier, BTRFS can send just the modified file; for the encrypted tier, it sends all modified extents of the monolithic `.img`.

These limitations apply only to Tier 3. The vast majority of VM data (application code, libraries, configs, logs) lives in Tier 2 where all BTRFS features work at full effectiveness.

### Snapshot Metadata

Each snapshot records the information needed for restore:

```json
{
  "snapshot_name": "my-app-v3",
  "created_at": "2026-03-23T14:30:00Z",
  "base_os_version": "ubuntu-24.04",
  "base_os_manifest_hash": "b3:a1b2c3d4...",
  "wrapped_dek": "<base64-encoded PRE-encrypted LUKS DEK>",
  "dek_encrypted_for": "<user-public-key-id>",
  "secure_partition_size_bytes": 10737418240,
  "original_vm_id": "550e8400-e29b-41d4-a716-446655440000",
  "original_config": { "vcpu_count": 2, "mem_size_mib": 512 }
}
```

The `wrapped_dek` is the LUKS DEK encrypted under the user's public key (via PRE). To restore the snapshot on a new VM, the DEK must be re-encrypted under the new VM's ephemeral key — this is exactly what PRE provides.

## PTY Console Architecture

The initramfs starts a PTY session immediately, giving the guest control of its own terminal from the first instruction.

### Why This Replaces tmux-on-Host

| tmux-on-host | initramfs PTY |
|---|---|
| Host process manages terminal state | Guest owns terminal from boot |
| Cannot observe pre-userspace boot | Console available during initramfs |
| Host-side complexity (session management) | Single vsock channel, guest-managed |
| Impedance mismatch (host termcap vs guest) | Guest controls its own terminfo |
| Requires SSH or API to attach | Direct vsock channel attachment |

### Implementation

The vsock protocol already supports channel-multiplexed binary PTY streams (channels 1-255). The initramfs extends this:

```
vsock channel 0: JSON control (status reports, key requests)
vsock channel 1: PTY stream (boot console → seamless transition → real shell)
vsock channel 2+: Additional PTY sessions (post-boot)
```

### mjolnir-boot-agent vs mjolnir-agent

The initramfs contains a **stripped-down** `mjolnir-boot-agent` — a minimal Rust binary with only the capabilities needed during the boot ceremony:

- vsock listener (control channel + PTY)
- Iroh endpoint (INJECT_ALPN for receiving LUKS DEK or VM ephemeral key)
- Blake3 manifest verification
- Signature verification (ED25519 + ML-DSA-87)
- Optional: PRE decryption (unwrap re-encrypted DEK)

After `pivot_root`, the full `mjolnir-agent` (existing guest agent at `native/mjolnir_guest_agent/`) takes over. The handoff:

1. `mjolnir-boot-agent` writes the Iroh keypair to `/etc/mjolnir/iroh.key` (the standard location)
2. `pivot_root` executes, `/sbin/init` starts
3. `mjolnir-agent` starts as a systemd service, loads the same Iroh key
4. `mjolnir-agent` re-opens vsock, takes over PTY channel 1 seamlessly
5. `mjolnir-boot-agent` process (now at `/mnt/initramfs/bin/...`) is no longer referenced

The two agents share the same vsock wire protocol (`Mjolnir.Vsock.Protocol`), so the host sees a continuous connection. The Iroh NodeId is preserved across the handoff.

### The initramfs `/init` script

This is the **Phase D+ version** (full verification + encryption). Phase A starts simpler (see Implementation Phases).

```bash
#!/bin/sh
# Mjolnir Verified Boot — initramfs /init

# 1. Start vsock PTY + Iroh endpoint immediately
/bin/mjolnir-boot-agent --boot-mode &
AGENT_PID=$!

# 2. All output goes to the PTY
exec > /dev/vsock-pty 2>&1

echo "Mjolnir Verified Boot"
echo "====================="
echo ""

# 3. Mount host share (read-only, for accessing base OS + userland + encrypted image)
mkdir -p /mnt/host
mount -t virtiofs myfs /mnt/host -o ro

# 4. Verify base OS Blake3 manifest signature
echo "[*] Verifying base OS integrity..."
/bin/mjolnir-boot-agent --verify-sig \
  /mnt/host/os/.manifest.blake3.sig \
  /mnt/host/os/.manifest.blake3 \
  /etc/boot-verify.pub /etc/boot-verify-pq.pub
if [ $? -ne 0 ]; then
  echo "[!] SIGNATURE VERIFICATION FAILED — refusing to boot"
  exec /bin/sh  # Drop to emergency shell
fi

# 5. Verify Blake3 manifest against actual filesystem
/bin/mjolnir-boot-agent --verify-manifest /mnt/host/os/
if [ $? -ne 0 ]; then
  echo "[!] BASE OS INTEGRITY CHECK FAILED — files tampered"
  exec /bin/sh
fi
echo "[+] Base OS integrity verified (Blake3)"

# 6. Wait for LUKS DEK via Iroh (user device injects directly)
echo "[*] Waiting for key injection via Iroh..."
/bin/mjolnir-boot-agent --wait-for-key --timeout=60
if [ $? -ne 0 ]; then
  echo "[!] Key injection timed out"
  echo "[!] Dropping to emergency shell (no access to encrypted data)"
  exec /bin/sh
fi
echo "[+] LUKS key received"

# 7. Open encrypted secure data partition (virtio-blk /dev/vda)
DEK_PATH=$(/bin/mjolnir-boot-agent --get-dek-path)
echo "[*] Unlocking encrypted secure partition..."
cryptsetup open /dev/vda secure \
  --type=luks2 --key-file="$DEK_PATH"
shred -u "$DEK_PATH"    # Destroy key material from tmpfs
echo "[+] Secure partition unlocked"

# 8. Remount host share as read-write (for semi-private userland)
umount /mnt/host
mount -t virtiofs myfs /mnt/host -o rw

# 9. Set up merged root via overlayfs
mkdir -p /mnt/merged /mnt/secure

# overlayfs: verified base (lower) + semi-private userland (upper)
mount -t overlay overlay /mnt/merged \
  -o lowerdir=/mnt/host/os,upperdir=/mnt/host/user/root-overlay,workdir=/mnt/host/user/overlay-work

# Bind mount semi-private data
mkdir -p /mnt/merged/data
mount --bind /mnt/host/user/data /mnt/merged/data

# Mount decrypted secure partition
mkdir -p /mnt/merged/data/secure
mount /dev/mapper/secure /mnt/merged/data/secure

echo "[+] Filesystem assembled (Blake3-verified base + encrypted secure partition)"
echo ""
echo "Booting into verified environment..."

# 10. Write Iroh key for full agent to pick up
mkdir -p /mnt/merged/etc/mjolnir
cp /tmp/iroh.key /mnt/merged/etc/mjolnir/iroh.key

# 11. pivot_root and exec init
cd /mnt/merged
mkdir -p mnt/initramfs
pivot_root . mnt/initramfs
exec chroot . /sbin/init
```

## Relationship to Existing Secrets Architecture

The existing secrets architecture (`docs/secrets-architecture.md`) provides encrypted environment variable storage via LUKS volumes with passphrase-based injection. The verified boot design **extends** this, not replaces it:

| Aspect | Existing Secrets Volume | Verified Boot Secure Partition |
|--------|------------------------|-------------------------------|
| **Purpose** | Store env vars (`DATABASE_URL`, etc.) | Encrypt all sensitive filesystem data |
| **LUKS cipher** | `aes-xts-plain64`, 512-bit | `aes-xts-plain64`, 512-bit (same) |
| **Key type** | Passphrase + Argon2id PBKDF | Raw 256-bit key (no PBKDF) |
| **Injection** | Iroh `INJECT_ALPN` (passphrase) | Iroh `INJECT_ALPN` (raw DEK or PRE key) |
| **Storage** | `/var/lib/mjolnir/secrets.luks` (inside guest) | `/dev/vda` via virtio-blk (host-side data.img) |
| **Lifecycle** | Created on first injection | Created at VM spawn |

**Coexistence**: In the verified boot model, the existing secrets volume can live *inside* the encrypted secure partition at `/data/secure/secrets.luks`. This provides defense-in-depth: even if the LUKS DEK for the secure partition were somehow compromised, the env var secrets have an additional encryption layer with a separate passphrase. Alternatively, env vars can be stored directly in `/data/secure/env/` since the partition is already encrypted.

**Migration**: Existing VMs without verified boot continue to work in legacy mode (direct virtio-fs root mount, passphrase-based secrets). Verified boot is opt-in per VM via the `initramfs_path` config field.

## Boot Image Build Pipeline

### Artifact Structure

```
boot-image/
├── vmlinux-ch                     # PVH kernel
├── vmlinux-ch.blake3              # Blake3 hash of kernel
├── vmlinux-ch.sig                 # MultiSig(ED25519 + ML-DSA-87) over hash
├── initramfs.img                  # cpio archive
├── initramfs.img.blake3
├── initramfs.img.sig
└── manifest.json                  # Ties all artifacts + hashes + sigs together
    manifest.json.sig              # Signed manifest
```

### Base OS Manifest Build

```bash
#!/bin/bash
# scripts/build-base-manifest.sh — Generate signed Blake3 manifest for a base OS subvolume

BASE_IMAGE=${1:-ubuntu-24.04}
SIGNING_KEY=${SIGNING_KEY:-keys/boot-signing.key}
BASE_DIR="/var/lib/mjolnir/@base/${BASE_IMAGE}"

echo "[*] Generating Blake3 manifest for ${BASE_DIR}..."

# Walk all files, hash each one, produce sorted manifest
find "${BASE_DIR}" -type f ! -name '.manifest.*' -print0 \
  | sort -z \
  | while IFS= read -r -d '' f; do
      relpath="${f#${BASE_DIR}/}"
      hash=$(b3sum --no-names "$f")
      printf '%s  %s\n' "$hash" "$relpath"
    done > "${BASE_DIR}/.manifest.txt"

# Hash the manifest itself
b3sum --no-names "${BASE_DIR}/.manifest.txt" > "${BASE_DIR}/.manifest.blake3"

# Sign the manifest hash
mjolnir-sign --key "$SIGNING_KEY" \
  --input "${BASE_DIR}/.manifest.blake3" \
  --output "${BASE_DIR}/.manifest.blake3.sig"

echo "[+] Manifest ready: $(cat ${BASE_DIR}/.manifest.blake3)"
echo "[+] $(wc -l < ${BASE_DIR}/.manifest.txt) files hashed"
```

### Initramfs Build

```bash
#!/bin/bash
# scripts/build-initramfs.sh

PUBKEY=${1:-keys/boot-verify.pub}
PUBKEY_PQ=${2:-keys/boot-verify-pq.pub}
OUTPUT=${3:-boot-image/initramfs.img}

WORKDIR=$(mktemp -d)
mkdir -p "${WORKDIR}"/{bin,etc,dev,proc,sys,mnt/host,mnt/merged,mnt/secure,tmp}

# Minimal userspace
cp /usr/bin/busybox "${WORKDIR}/bin/"
ln -s busybox "${WORKDIR}/bin/sh"
for cmd in mount umount mkdir cat shred cp cd; do
  ln -s busybox "${WORKDIR}/bin/${cmd}"
done

# Cryptographic tools
cp target/x86_64-unknown-linux-musl/release/mjolnir-boot-agent "${WORKDIR}/bin/"
cp /usr/sbin/cryptsetup "${WORKDIR}/bin/"   # Static musl build

# Public keys for signature verification
cp "$PUBKEY" "${WORKDIR}/etc/boot-verify.pub"
cp "$PUBKEY_PQ" "${WORKDIR}/etc/boot-verify-pq.pub"

# Init script
cp scripts/initramfs-init.sh "${WORKDIR}/init"
chmod +x "${WORKDIR}/init"

# Build cpio archive
(cd "${WORKDIR}" && find . | cpio -o -H newc | gzip -9) > "$OUTPUT"
echo "[+] Initramfs: $(du -h $OUTPUT | cut -f1) compressed"

rm -rf "${WORKDIR}"
```

### Initramfs Contents

```
/init                       # Boot script (see above)
/bin/busybox                # Minimal userspace (sh, mount, cat, shred, mkdir)
/bin/mjolnir-boot-agent     # Rust binary: vsock PTY + Iroh + Blake3 verify + sig verify
/bin/cryptsetup             # LUKS open (static-linked against musl)
/etc/boot-verify.pub        # ED25519 public key for signature verification
/etc/boot-verify-pq.pub    # ML-DSA-87 public key for PQ signature verification
```

Target size: ~8-15MB compressed. No `veritysetup` needed (replaced by Blake3 manifest verification in the boot agent binary).

## Estimated Boot Latency

| Phase | Duration | Notes |
|-------|----------|-------|
| CH kernel + initramfs load | ~200ms | Existing |
| Blake3 manifest signature verify | ~10ms | ED25519 + ML-DSA-87 verify |
| Blake3 base OS verification | ~200ms | ~1GB base at 5+ GB/s (Blake3 with AVX-512) |
| Iroh key injection | 200-500ms | QUIC handshake + E2E key delivery from user device |
| LUKS open | ~50ms | Raw key injection (no PBKDF — much faster than Argon2id) |
| Overlay setup + pivot_root | ~50ms | overlayfs + bind mounts |
| **Total added** | **~500-800ms** | Over current ~2-3s boot |

Expected total boot time: ~2.5-3.8 seconds for a fully verified, encrypted boot.

With spot-check mode (critical files only instead of full manifest), Blake3 verification drops to ~10ms and total added latency is ~300-600ms.

## Counterfactuals and Trade-offs

### 1. Why Not dm-verity?

dm-verity provides continuous runtime integrity checking but requires a block device, forcing the base OS off BTRFS onto ext4 via virtio-blk. This sacrifices virtio-fs live sharing, reflink cloning, deduplication, and compression for the OS tier. Blake3 manifest verification provides equivalent tamper detection at boot time. The base OS is mounted read-only — runtime re-verification is unnecessary for our threat model.

### 2. Why Not Encrypt Everything?

Encrypting all user data (Tier 2 + Tier 3) would require either: (a) the entire filesystem on LUKS via virtio-blk, losing virtio-fs entirely, or (b) LUKS-over-loopback-over-virtio-fs, adding three layers of I/O indirection. Either approach eliminates BTRFS's most valuable features for the majority of data. The three-tier model provides full encryption where it matters (secrets, PII, sensitive data) while preserving BTRFS superpowers (dedup, compression, incremental sync) for everything else.

Additionally, virtio-fs with DAX gives the host memory-mapped access to guest filesystem contents. Even LUKS-over-virtio-fs does not protect against a host inspecting virtiofsd's shared memory. True host-opaque encryption requires either virtio-blk (Tier 3) or application-level encryption (Recrypt).

### 3. User Must Be Online for Primary Path

The user-device-generated ephemeral keypair (primary path) requires the user to be online during VM spawn to inject the LUKS DEK via Iroh. This is acceptable for interactive use. For autonomous spawning (dormant restoration, scaling), the pre-committed key pool (offline path) provides a fallback with a slightly weaker trust model.

### 4. Offline Boot

If the Identikey user is unreachable AND no pre-committed keys are available, the VM boots but cannot unlock its encrypted secure partition. This is by design — it's the zero-knowledge property. The initramfs should:

- Retry with exponential backoff (5s, 10s, 20s...)
- Display status on the PTY console: "Waiting for key provider..."
- After timeout (configurable, default 60s): drop to a minimal shell for debugging
- Semi-private userland (`/data/`) is still accessible — only `/data/secure/` requires the key

### 5. Signing Key Trust

The boot image signing key is a single point of trust. Whoever holds it can produce a malicious initramfs that exfiltrates LUKS keys. Mitigations:

- **Hardware-backed key**: Store signing key on YubiKey or HSM
- **Multi-party signing**: Require 2-of-N threshold signatures
- **Transparency log**: Publish signed boot image hashes to an append-only log

### 6. Rollback Protection

Blake3 manifest verification alone doesn't prevent booting an older (potentially vulnerable) base OS image. For rollback protection:

- Include a monotonic version counter in the signed manifest
- The initramfs checks the counter against a stored minimum (in LUKS header metadata or a TPM-like counter)
- Refuse to boot if the version is below the minimum

### 7. Secure Partition Sizing

The `data.img` LUKS partition is created at VM spawn with a fixed size. Resizing a LUKS volume requires unmounting, which means VM downtime. Options:

- Default to a generous size (e.g., 10GB) — most secure data is small (keys, credentials, PII records)
- Support online resize via `cryptsetup resize` + `resize2fs` if the underlying image is grown
- Allow the user to specify size at spawn time

## Implementation Phases

### Phase A: Minimal Initramfs Boot (No Encryption, No Verification)

Prove the boot chain works:
1. Build minimal initramfs with busybox + `/init` script
2. Add `initramfs_path` to CH config, update `kernel_payload/1`
3. initramfs mounts virtio-fs and does `pivot_root` (same as today, but via initramfs)
4. Verify PTY console works during initramfs phase via `mjolnir-boot-agent` (vsock only, no Iroh)

### Phase B: Blake3 Base OS Verification

Add integrity checking:
1. Build Blake3 manifest for the base OS subvolume (`scripts/build-base-manifest.sh`)
2. Add `--verify-manifest` and `--verify-sig` commands to `mjolnir-boot-agent`
3. initramfs verifies Blake3 manifest before pivoting
4. Set up overlayfs: base OS (lower, read-only) + semi-private userland (upper, writable)

### Phase C: LUKS Encrypted Secure Partition (Direct DEK via Iroh)

Add encryption with the simplest key injection (no PRE yet):
1. Create LUKS-formatted `data.img` at VM spawn (`cryptsetup luksFormat --cipher aes-xts-plain64 --key-size 512 --key-file <random_dek>`)
2. Add `secure_data_image` to CH config for virtio-blk
3. Extend `mjolnir-boot-agent` with Iroh endpoint for INJECT_ALPN
4. User device delivers raw DEK via Iroh (E2E)
5. initramfs receives DEK, opens LUKS on `/dev/vda`, assembles overlay, pivots
6. Establish agent handoff: boot-agent writes Iroh key, full agent picks it up

### Phase D: Identikey/Recrypt Key Injection (Full PRE)

Complete the zero-knowledge key flow:
1. User device generates VM ephemeral PRE keypair at spawn time
2. Spawn API accepts `vm_public_key` and `recryption_key`
3. Host stores `rk` with VM metadata, performs `recrypt()` at boot
4. User device injects `vm_sk` via Iroh INJECT_ALPN
5. Boot agent decrypts re-wrapped DEK using `vm_sk`
6. Implement pre-committed key pool for offline spawning (D+)

### Phase E: Signing Tooling + Remote Attestation

Production signing pipeline:
1. `mjolnir-sign` CLI tool (wraps `recrypt-core::sign`)
2. Boot image + manifest build scripts
3. Manifest generation and verification
4. Init script signature verification (ED25519 + ML-DSA-87 dual check)
5. Remote attestation: client verifies guest Blake3 manifest hash before key delivery
6. Key management (generation, rotation, multi-party)

## References

### Mjolnir
- `lib/mjolnir/cloud_hypervisor/config.ex` — Current CH config (to be extended)
- `lib/mjolnir/cloud_hypervisor/client.ex` — CH API client
- `lib/mjolnir/vm.ex` — VM lifecycle GenServer
- `lib/mjolnir/virtiofs.ex` — virtiofsd management (scope unchanged)
- `native/mjolnir_guest_agent/src/iroh.rs` — Iroh endpoint + INJECT_ALPN handler
- `native/mjolnir_guest_agent/src/secrets.rs` — LUKS engine + one-shot injection guard
- `docs/research/zero-knowledge-vm-storage/synthesis.md` — Zero-knowledge architecture research
- `docs/secrets-architecture.md` — Existing LUKS secrets volume design (coexists with verified boot)

### Recrypt / Identikey
- `crates/recrypt-core/src/hybrid/mod.rs` — HybridEncryptor (encrypt/recrypt/decrypt)
- `crates/recrypt-core/src/sign/mod.rs` — MultiSig (ED25519 + ML-DSA-87)
- `crates/recrypt-core/src/pre/backends/lattice.rs` — OpenFHE BFV PRE backend
- `crates/recrypt-core/src/pre/keys.rs` — RecryptKey (pair-specific binding)
- `crates/recrypt-core/src/pre/traits.rs` — PreBackend trait (generate_recrypt_key signature)
- `crates/recrypt-proto/src/bao_stream.rs` — Blake3/Bao streaming verification
