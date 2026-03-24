# Initramfs Verified Boot Design

Mjolnir's boot chain gains a cryptographic trust boundary by inserting an initramfs between kernel load and rootfs mount. The initramfs creates a verified, authenticated execution environment before any user data is accessible — enabling dm-verity integrity on the immutable base OS, LUKS-encrypted mutable userdata unlocked via Identikey/Recrypt key injection, and a guest-owned PTY console from the first instruction.

## Motivation

The current boot flow has no verification step:

```
CH loads kernel → kernel mounts virtio-fs directly → userspace
```

The kernel trusts whatever virtio-fs serves. There is no point at which we can verify integrity, inject cryptographic keys, or gate boot on authentication. The initramfs fixes all three.

## Architecture: Three-Layer Separation

```
Layer 1: BOOT IMAGE (kernel + initramfs)
  - Signed with ED25519 + ML-DSA-87 (MultiSig)
  - Immutable, versioned by signature over content hash
  - Contains public keys, Iroh bootstrap, /init

Layer 2: BASE OS (ext4 block image)
  - Protected by dm-verity (SHA-256 Merkle tree)
  - Read-only, mounted after hash verification
  - Contains OS packages, libraries, system binaries

Layer 3: USERDATA (BTRFS subvolume via virtio-fs)
  - Encrypted via LUKS2/dm-crypt (see Cipher Suite for exact cipher)
  - Mutable, CoW-versioned via BTRFS snapshots
  - Key injected at boot from Identikey via Iroh + recryption proxy
```

### Design Principles

1. **The initramfs is the trust root.** It runs before any unverified code. It contains the public keys needed to verify everything else.
2. **The boot volume is not BTRFS.** It's a signed ext4 image with dm-verity. BTRFS is reserved for mutable userdata where CoW versioning matters.
3. **Signing is versioning.** A dm-verity root hash uniquely identifies a base OS image. Signing that hash with a timestamped signature creates an immutable version record.
4. **The VM cannot start without cryptographic authorization.** The LUKS key is not on-disk. It arrives via Iroh from Identikey (or the recryption proxy). No key, no boot.
5. **The host never sees plaintext keys.** All key material flows through end-to-end encrypted channels (Iroh QUIC) or proxy recryption (PRE transforms without decrypting).

## Boot Sequence

```
Cloud Hypervisor loads:
  ├── vmlinux-ch          (PVH kernel, signed separately)
  └── initramfs.img       (cpio archive, signed separately)

initramfs /init:
  1. Mount virtio-fs (raw BTRFS host share) at /mnt/host READONLY
  2. Verify dm-verity root hash signature:
     └── Read root hash from /mnt/host/boot/base-os.roothash
     └── Read signature from /mnt/host/boot/base-os.roothash.sig
     └── Verify MultiSig against pubkeys baked into initramfs
     └── Compare verified hash against mjolnir.roothash from cmdline
  3. Activate dm-verity: veritysetup open /dev/vda base-os \
       --hash-device=/mnt/host/boot/base-os.verity \
       --root-hash=<verified_hash>
  4. Mount /dev/mapper/base-os at /mnt/base (read-only ext4)
  5. Start vsock listener → present boot console on PTY channel
  6. Start Iroh endpoint (using guest's pre-loaded Iroh key)
  7. Receive VM ephemeral private key via Iroh IdentiKey Inject protocol
     └── User device connects directly to guest (INJECT_ALPN, E2E encrypted)
     └── Delivers PRE secret key (kind=3, pre-secret-key) for this VM session
  8. Receive re-wrapped DEK via vsock from host
  9. Decrypt DEK using VM ephemeral private key → recover raw 256-bit LUKS key
  10. Open LUKS: cryptsetup open /mnt/host/userdata.luks userdata \
        --type=luks2 --key-file=<decrypted_dek>
  11. Shred key material from tmpfs
  12. Set up overlayfs for mutable system state:
      └── Mount LUKS userdata at /mnt/userdata
      └── overlayfs: lower=/mnt/base/etc upper=/mnt/userdata/etc-overlay merged=/mnt/merged/etc
      └── bind-mount /mnt/userdata/data → /mnt/merged/data
  13. pivot_root /mnt/merged → exec /sbin/init
  14. Hand off vsock PTY from mjolnir-boot-agent → mjolnir-agent (full guest agent)
```

## Cipher Suite

### Chosen Algorithms

| Function | Algorithm | Exact Cipher String | Key Size | Rationale |
|----------|-----------|-------------------|----------|-----------|
| dm-verity hash tree | SHA-256 | `--hash=sha256` | 256-bit | Mainline kernel support. dm-verity has limited hash algorithm options. SHA-256 is fine for integrity — it's not protecting secrecy. Blake3 would require a custom kernel hash driver; SHA-256 is pragmatic. |
| Boot image signing | ED25519 + ML-DSA-87 | N/A (userspace) | 256-bit + PQ | Dual classical + post-quantum signatures. Matches `recrypt-core::sign::MultiSig`. Both must verify for the signature to be accepted. |
| LUKS bulk encryption | AES-256-XTS | `--cipher aes-xts-plain64 --key-size 512` | 512-bit (256 effective) | Matches existing secrets architecture (`docs/secrets-architecture.md`). AES-XTS is the Linux dm-crypt standard with hardware AES-NI acceleration. XTS mode uses two 256-bit keys (512 total) for tweakable encryption. |
| LUKS key derivation | None (raw key) | `--key-file` (not passphrase) | 256-bit | Unlike the existing secrets volume (which uses Argon2id PBKDF from a passphrase), the verified boot injects a raw 256-bit key. No PBKDF overhead. |
| DEK wrapping (PRE) | OpenFHE BFV lattice | N/A (userspace) | Post-quantum | 96-byte `KeyMaterial` bundle (32B sym key + 24B nonce + 32B plaintext hash + 8B size) is PRE-encrypted. ~5-10KB ciphertext. Recryption operates on wrapped key only — milliseconds regardless of data size. |
| Key transport | Iroh QUIC + TLS 1.3 | N/A (protocol) | Session keys | End-to-end encrypted channel bypassing the host. DEK ciphertext travels inside this tunnel. |
| Content hashing | Blake3 | N/A (userspace) | 256-bit | Used for all application-level hashing (file integrity, content addressing, Bao streaming verification). 4-8x faster than Blake2b. |

### Why AES-XTS for LUKS (Not XChaCha20)

The existing secrets architecture (`docs/secrets-architecture.md`) uses `aes-xts-plain64` with 512-bit keys. We retain this for LUKS because:

1. **dm-crypt cipher name compatibility** — `cryptsetup` expects kernel crypto API names. `aes-xts-plain64` is universally supported. There is no `xchacha20-poly1305` dm-crypt cipher name in mainline kernels. The closest alternatives (`chacha20-poly1305`, `adiantum`) require `CONFIG_CRYPTO_CHACHA20POLY1305` or `CONFIG_CRYPTO_ADIANTUM`.
2. **AES-NI hardware acceleration** — AES-XTS runs at ~3-5 GB/s on modern x86_64 with AES-NI. XChaCha20 (software-only in kernel) runs at ~1-2 GB/s. For block device encryption, this matters.
3. **Consistency** — Using the same LUKS cipher across both the secrets volume and userdata volume simplifies kernel config requirements and debugging.
4. **XChaCha20 remains the choice for streaming encryption** — The Recrypt stack uses XChaCha20-Poly1305 for file-level encryption (btrfs send streams, content-addressed blobs). Different layers use the best cipher for their context.

### Why SHA-256 for dm-verity (Not Blake3)

The Linux kernel's dm-verity implementation supports SHA-256, SHA-512, and SHA-3. Adding Blake3 would require:
- A custom kernel crypto module (`crypto_register_shash`)
- Patching the dm-verity target to recognize the algorithm
- Maintaining a custom kernel build indefinitely

SHA-256 is the right choice here because:
1. dm-verity protects integrity of the **read-only base OS** — not secrecy
2. SHA-256 has hardware acceleration (SHA-NI) on x86_64
3. The base OS image is verified once at boot, not continuously hashed
4. The real security boundary (LUKS encryption) uses AES-XTS with full cipher freedom

Blake3 is used everywhere else: content addressing, Bao streaming verification, file hashing in the Recrypt stack.

### Algorithm Substitutability

The design supports cipher agility at each layer:

- **dm-verity**: Change `--hash` flag in `veritysetup format`. Requires kernel support.
- **Boot signing**: The initramfs signature format includes an algorithm identifier. New algorithms can be added without changing the verification flow.
- **LUKS**: `cryptsetup` supports pluggable ciphers. Switch via `--cipher` at format time. If kernel adds `xchacha20-poly1305` as a dm-crypt cipher, migration is a reformat.
- **DEK wrapping**: Recrypt's `PreBackend` trait abstracts over backends. Swap OpenFHE BFV for any future PRE scheme.

### Kernel Crypto Requirements

The guest kernel must have these options enabled:

```
CONFIG_BLK_DEV_DM=y           # Device mapper
CONFIG_DM_CRYPT=y              # dm-crypt (LUKS)
CONFIG_DM_VERITY=y             # dm-verity (base OS integrity)
CONFIG_CRYPTO_XTS=y            # XTS block cipher mode
CONFIG_CRYPTO_AES=y            # AES cipher
CONFIG_CRYPTO_SHA256=y         # SHA-256 for dm-verity
CONFIG_CRYPTO_AES_NI_INTEL=y   # AES-NI hardware acceleration (optional but recommended)
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
                                                              dm-verity verified
                                                              Iroh endpoint ready
                               7. authorize_inject_peer(     (via vsock configure)
                                    user_node_id)
                                                              Add user to
                                                              AUTHORIZED_INJECT_PEERS
8. Connect to guest via Iroh
   (INJECT_ALPN)
   Verify dm-verity roothash
   (optional remote attestation)
9. Send vm_kp.secret via Iroh ──────────────────────────────> 10. Receive vm_sk
   (E2E encrypted, bypasses host)                                 (one-shot injection guard)
                               11. rewrapped = recrypt(rk,
                                     wrapped_dek)
                               12. Deliver rewrapped ───────> 13. decrypt(vm_sk, rewrapped)
                                   via vsock                       → recover LUKS DEK
                                                              14. cryptsetup open
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

### Optional: Remote Attestation via dm-verity Root Hash

Before delivering `vm_sk` (primary path, step 9), the user device can verify the guest booted the correct image:

1. User device requests dm-verity root hash from guest via Iroh
2. Boot agent reads `mjolnir.roothash` from `/proc/cmdline`, reports it
3. User device compares against the expected root hash from the signed manifest
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
| `luks:<name>` | Open LUKS device with this dm-crypt mapper name | `luks:userdata`, `luks:mjolnir-secrets` |
| `env` | Load as environment variables | — |
| `/path/...` | Write to this path (tmpfs, mode 0600) | `/run/mjolnir/secrets/tls.pem` |
| `mem` | Hold in memory only, never touch disk | — |

### COSE_Key Payloads (kind=3)

When `kind=3` (key), the payload is a CBOR-encoded COSE_Key map (RFC 9052 §7). This provides standardized key type identification, algorithm binding, and interoperability with COSE-aware tooling — the same format used by WebAuthn/FIDO2 for attestation keys.

#### Why COSE_Key

- **Self-describing**: The key type (`kty`) and algorithm (`alg`) are encoded in the key itself, not inferred from context. A receiver can determine what kind of key it holds without out-of-band information.
- **Algorithm agility**: Adding new key types (ML-KEM, X-Wing, future PQ algorithms) means adding a `kty` value, not changing the wire format.
- **IANA registry**: Standard `kty` values (OKP, EC2, symmetric) are IANA-registered. We extend into the private-use range for lattice PRE keys (`kty: -1`).
- **FIDO2 alignment**: The same serialization used for WebAuthn public key credentials. If Mjolnir ever interoperates with hardware security keys or passkeys, the format is already compatible.

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

### Example Frames

**Boot key injection (verified boot, Phase D) — COSE_Key payload:**

```
49 49                         # magic "II"
00 00 07                      # meta_len = 7
A2 01 03 04 F5               # CBOR meta: {1: 3, 4: true}  (kind=key, zeroize=true)
A5                            # payload: COSE_Key map (5 entries)
  01 20                       #   kty: -1 (lattice)
  02 50 <16-byte vm-uuid>    #   kid: VM identifier
  03 3A 0000FFFF             #   alg: -65537 (OpenFHE-BFV-PRE)
  04 82 04 06                #   key_ops: [decrypt, unwrap]
  20 59 <len> <PRE key bytes>#   -1: private key material
```

Response: `{1: true, 3: "mem"}`

**Raw LUKS key (Phase C, direct DEK delivery):**

```
49 49
00 00 0C
A2 01 02 02 6E              # CBOR meta: {1: 2, 2: "luks:userdata"}
  6C 75 6B 73 3A 75 73 65 72 64 61 74 61
<32 bytes raw key>           # payload: raw symmetric key
```

Response: `{1: true, 3: "luks:userdata", 4: false}`

**Passphrase injection (existing secrets flow):**

```
49 49
00 00 1C
A2 01 01 02 74              # CBOR meta: {1: 1, 2: "luks:mjolnir-secrets"}
  6C 75 6B 73 3A 6D 6A 6F 6C 6E 69 72 2D 73 65 63 72 65 74 73
<passphrase bytes>
```

**Zero-metadata (simplest possible):**

```
49 49 00 00 00               # magic + meta_len=0
<secret bytes>               # kind=opaque, dest=mem, once=true, zeroize=true
```

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

### On COSE for Untrusted Channels

The IdentiKey Inject protocol does not use COSE signing or encryption at the transport layer — Iroh QUIC TLS 1.3 already provides authenticated, encrypted delivery. COSE's signing/encryption (COSE_Sign1, COSE_Encrypt0) is designed for payloads that travel through **untrusted intermediaries** where the transport cannot be relied upon.

This becomes relevant for a future use case: **standalone capability tokens**. When encrypted key material or authorization tokens are stored in unknown locations (distributed caches, content-addressed storage, passed through message queues), they exist outside any authenticated channel. In that context, wrapping them in COSE_Encrypt0 (with the recipient's COSE_Key) or COSE_Sign1 (for integrity without confidentiality) provides self-contained protection that travels with the payload. The COSE_Key format we adopt here for `kind=3` payloads ensures these keys will be directly usable as COSE recipients if/when we add COSE-wrapped tokens.

The migration path:
- **Today**: IdentiKey Inject over Iroh (transport-secured, COSE_Key for key payloads)
- **Future**: COSE_Encrypt0 wrapping for at-rest tokens (self-secured, same COSE_Key format)

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
├── boot/                              # Signed boot artifacts (immutable)
│   ├── vmlinux-ch                     # PVH kernel
│   ├── vmlinux-ch.sig                 # MultiSig over kernel hash
│   ├── initramfs.img                  # cpio archive
│   ├── initramfs.img.sig              # MultiSig over initramfs hash
│   └── base-os/
│       ├── ubuntu-24.04.img           # ext4 block image (dm-verity protected)
│       ├── ubuntu-24.04.verity        # dm-verity hash tree
│       ├── ubuntu-24.04.roothash      # 32-byte root hash
│       └── ubuntu-24.04.roothash.sig  # MultiSig over root hash
│
├── @vms/<uuid>/                       # Per-VM BTRFS subvolume (virtio-fs shared)
│   └── userdata.luks                  # LUKS2-encrypted user data
│
└── @snapshots/<name>/                 # Named snapshots (BTRFS CoW)
    ├── userdata.luks                  # Encrypted userdata snapshot
    └── metadata.json                  # Snapshot metadata (wrapped DEK, etc.)
```

### Guest-Side (After Boot)

```
/                    ← overlayfs merged root
├── /sbin/init       ← from dm-verity base (read-only lower)
├── /usr/...         ← from dm-verity base (read-only lower)
├── /etc/...         ← overlayfs: base /etc (lower) + userdata etc-overlay (upper)
│                      Applications see a single merged /etc that is writable.
│                      Changes persist to the LUKS-encrypted upper layer.
│
/data                ← bind mount from LUKS-decrypted userdata
├── /data/home/
├── /data/var/
└── /data/app/       ← application code and state
```

**Overlay mount strategy**: The base OS provides the read-only lower layer for the entire root filesystem. An overlayfs is set up with the LUKS-encrypted userdata as the upper (writable) layer. This means:
- System binaries (`/usr`, `/sbin`) come from the verified base — immutable
- Configuration (`/etc`) is an overlay — base provides defaults, userdata provides overrides
- User data (`/data`) is a direct bind mount from the encrypted volume
- Applications do not need special path awareness — standard `/etc`, `/home`, etc. paths work

## Cloud Hypervisor Configuration Changes

The VM needs both virtio-blk (for the dm-verity base OS image) and virtio-fs (for the encrypted userdata BTRFS subvolume).

### Config Struct Additions

```elixir
# lib/mjolnir/cloud_hypervisor/config.ex

typedstruct do
  # ... existing fields ...

  # New fields for verified boot
  field(:initramfs_path, String.t(), default: nil)
  field(:base_os_image, String.t(), default: nil)        # ext4 dm-verity image path
  field(:base_os_roothash, String.t(), default: nil)      # dm-verity root hash (hex)
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

defp boot_args(%__MODULE__{base_os_roothash: nil} = config) do
  # Legacy mode: direct virtio-fs root mount
  config.boot_args
end

defp boot_args(%__MODULE__{base_os_roothash: roothash} = config) do
  # Verified boot: initramfs handles mounting
  # Pass roothash and VM network config via cmdline
  "console=ttyS0 reboot=k panic=1 " <>
    "mjolnir.roothash=#{roothash} " <>
    "mjolnir.vm_ip=#{config.network_interface[:guest_ip]} " <>
    "mjolnir.vm_cid=#{config.vsock_cid}"
end
```

### Disk Configuration (New)

```elixir
def disk_config(%__MODULE__{base_os_image: nil}), do: nil

def disk_config(%__MODULE__{base_os_image: path}) do
  [
    %{
      "path" => path,
      "readonly" => true
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

### virtiofsd Scope Change

Currently, `Mjolnir.VirtioFS` (`lib/mjolnir/virtiofs.ex`) starts virtiofsd to share the entire rootfs BTRFS subvolume. Under verified boot, virtiofsd shares **only the userdata subvolume**:

- **Current**: `shared_dir` = `@vms/<uuid>/` (full rootfs including OS)
- **Verified boot**: `shared_dir` = `@vms/<uuid>/` (now contains only `userdata.luks` + metadata)

The base OS comes via virtio-blk (`/dev/vda`), not virtio-fs. The virtiofsd still runs for userdata access, but its scope is reduced to the encrypted user partition.

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
- Iroh endpoint (INJECT_ALPN for receiving VM ephemeral key)
- Signature verification (ED25519 + ML-DSA-87)
- PRE decryption (unwrap re-encrypted DEK)

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
# 1. Start vsock PTY + Iroh endpoint immediately
/bin/mjolnir-boot-agent --boot-mode &
AGENT_PID=$!

# 2. All output goes to the PTY
exec > /dev/vsock-pty 2>&1

echo "Mjolnir Verified Boot"
echo "====================="
echo ""

# 3. Mount host share (read-only, for accessing boot artifacts + userdata)
mount -t virtiofs myfs /mnt/host -o ro

# 4. Verify base OS root hash signature BEFORE trusting it
echo "[*] Verifying base OS signature..."
/bin/mjolnir-boot-agent --verify-sig \
  /mnt/host/boot/base-os.roothash.sig \
  /mnt/host/boot/base-os.roothash \
  /etc/boot-verify.pub /etc/boot-verify-pq.pub
if [ $? -ne 0 ]; then
  echo "[!] SIGNATURE VERIFICATION FAILED — refusing to boot"
  exec /bin/sh  # Drop to emergency shell
fi

# 5. Read verified root hash
ROOTHASH=$(cat /mnt/host/boot/base-os.roothash)
CMDLINE_HASH=$(cat /proc/cmdline | tr ' ' '\n' | grep mjolnir.roothash | cut -d= -f2)
if [ "$ROOTHASH" != "$CMDLINE_HASH" ]; then
  echo "[!] Root hash mismatch (file vs cmdline) — refusing to boot"
  exec /bin/sh
fi
echo "[+] Base OS signature verified: $ROOTHASH"

# 6. Activate dm-verity
veritysetup open /dev/vda base-os \
  --hash-device=/mnt/host/boot/base-os.verity \
  --root-hash="$ROOTHASH"
echo "[+] dm-verity activated"

# 7. Mount verified base
mount -o ro /dev/mapper/base-os /mnt/base
echo "[+] Base OS mounted (read-only, dm-verity)"

# 8. Wait for VM ephemeral key via Iroh (user device injects directly)
echo "[*] Waiting for key injection via Iroh..."
/bin/mjolnir-boot-agent --wait-for-key --timeout=60
if [ $? -ne 0 ]; then
  echo "[!] Key injection timed out"
  echo "[!] Dropping to emergency shell (no access to encrypted data)"
  exec /bin/sh
fi
echo "[+] Ephemeral key received"

# 9. Wait for re-wrapped DEK via vsock (host delivers after recryption)
echo "[*] Requesting encrypted DEK from host..."
DEK_PATH=$(/bin/mjolnir-boot-agent --decrypt-dek)
echo "[+] DEK decrypted"

# 10. Open encrypted userdata
echo "[*] Unlocking encrypted userdata..."
cryptsetup open /mnt/host/userdata.luks userdata \
  --type=luks2 --key-file="$DEK_PATH"
shred -u "$DEK_PATH"    # Destroy key material from tmpfs
echo "[+] Userdata unlocked"

# 11. Set up overlayfs
mkdir -p /mnt/merged /mnt/userdata /mnt/work
mount /dev/mapper/userdata /mnt/userdata
# Overlay for /etc: base provides defaults, userdata provides overrides
mkdir -p /mnt/userdata/etc-overlay /mnt/userdata/etc-work
mount -t overlay overlay /mnt/base/etc \
  -o lowerdir=/mnt/base/etc,upperdir=/mnt/userdata/etc-overlay,workdir=/mnt/userdata/etc-work

# Bind mount userdata
mkdir -p /mnt/base/data
mount --bind /mnt/userdata/data /mnt/base/data

echo "[+] Filesystem assembled (dm-verity base + encrypted overlay)"
echo ""
echo "Booting into verified environment..."

# 12. Write Iroh key for full agent to pick up
cp /tmp/iroh.key /mnt/base/etc/mjolnir/iroh.key

# 13. pivot_root and exec init
cd /mnt/base
mkdir -p mnt/initramfs
pivot_root . mnt/initramfs
exec chroot . /sbin/init
```

## Relationship to Existing Secrets Architecture

The existing secrets architecture (`docs/secrets-architecture.md`) provides encrypted environment variable storage via LUKS volumes with passphrase-based injection. The verified boot design **extends** this, not replaces it:

| Aspect | Existing Secrets Volume | Verified Boot Userdata |
|--------|------------------------|----------------------|
| **Purpose** | Store env vars (`DATABASE_URL`, etc.) | Encrypt all user filesystem data |
| **LUKS cipher** | `aes-xts-plain64`, 512-bit | `aes-xts-plain64`, 512-bit (same) |
| **Key type** | Passphrase + Argon2id PBKDF | Raw 256-bit key (no PBKDF) |
| **Injection** | Iroh `INJECT_ALPN` (passphrase) | Iroh `INJECT_ALPN` (PRE secret key) |
| **Volume location** | `/var/lib/mjolnir/secrets.luks` (inside guest) | `@vms/<uuid>/userdata.luks` (on host, virtio-fs) |
| **Lifecycle** | Created on first injection | Created at VM spawn |

**Coexistence**: In the verified boot model, the secrets volume lives *inside* the encrypted userdata. Once the userdata LUKS is unlocked, the secrets volume at `/data/secrets.luks` can be opened with the existing passphrase flow. The two layers are complementary:
- Userdata LUKS: encrypts the entire user filesystem (key via PRE)
- Secrets LUKS: additional isolation for sensitive env vars (key via passphrase)

**Migration**: Existing VMs without verified boot continue to work in legacy mode (direct virtio-fs root mount, passphrase-based secrets). Verified boot is opt-in per VM via the `base_os_roothash` config field.

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
├── base-os/
│   ├── ubuntu-24.04.img           # ext4 image
│   ├── ubuntu-24.04.verity        # dm-verity hash tree (SHA-256)
│   ├── ubuntu-24.04.roothash      # 32-byte root hash
│   └── ubuntu-24.04.roothash.sig  # MultiSig over root hash
└── manifest.json                  # Ties all artifacts + hashes + sigs together
    manifest.json.sig              # Signed manifest
```

### Build Script (Conceptual)

```bash
#!/bin/bash
# scripts/build-boot-image.sh

SIGNING_KEY=${SIGNING_KEY:-keys/boot-signing.key}
BASE_IMAGE=${1:-ubuntu-24.04}

# 1. Build base OS ext4 image from BTRFS subvolume
echo "[*] Creating ext4 image from @base/${BASE_IMAGE}..."
mkfs.ext4 -d "/var/lib/mjolnir/@base/${BASE_IMAGE}" \
  "boot-image/base-os/${BASE_IMAGE}.img" 2G

# 2. Generate dm-verity hash tree
echo "[*] Generating dm-verity hash tree (SHA-256)..."
veritysetup format \
  "boot-image/base-os/${BASE_IMAGE}.img" \
  "boot-image/base-os/${BASE_IMAGE}.verity" \
  --hash=sha256 \
  | grep "Root hash" | awk '{print $3}' \
  > "boot-image/base-os/${BASE_IMAGE}.roothash"

# 3. Sign the root hash
echo "[*] Signing root hash..."
mjolnir-sign --key "$SIGNING_KEY" \
  --input "boot-image/base-os/${BASE_IMAGE}.roothash" \
  --output "boot-image/base-os/${BASE_IMAGE}.roothash.sig"

# 4. Build initramfs (contains pubkey, boot agent, busybox, veritysetup, cryptsetup)
echo "[*] Building initramfs..."
./scripts/build-initramfs.sh \
  --pubkey "keys/boot-verify.pub" \
  --output "boot-image/initramfs.img"

# 5. Sign initramfs and kernel
for artifact in vmlinux-ch initramfs.img; do
  blake3sum "boot-image/${artifact}" | awk '{print $1}' > "boot-image/${artifact}.blake3"
  mjolnir-sign --key "$SIGNING_KEY" \
    --input "boot-image/${artifact}.blake3" \
    --output "boot-image/${artifact}.sig"
done

# 6. Generate manifest
echo "[*] Generating signed manifest..."
# manifest.json includes all hashes and artifact metadata
python3 scripts/gen-manifest.py boot-image/ > boot-image/manifest.json
mjolnir-sign --key "$SIGNING_KEY" \
  --input boot-image/manifest.json \
  --output boot-image/manifest.json.sig

echo "[+] Boot image ready. Root hash: $(cat boot-image/base-os/${BASE_IMAGE}.roothash)"
```

### Initramfs Contents

The initramfs cpio archive contains only what's needed for the boot ceremony:

```
/init                       # Boot script (see above)
/bin/busybox                # Minimal userspace (sh, mount, cat, shred, mkdir)
/bin/mjolnir-boot-agent     # Rust binary: vsock PTY + Iroh + sig verify + PRE decrypt
/bin/veritysetup            # dm-verity activation (static-linked against musl)
/bin/cryptsetup             # LUKS open (static-linked against musl)
/etc/boot-verify.pub        # ED25519 public key for signature verification
/etc/boot-verify-pq.pub    # ML-DSA-87 public key for PQ signature verification
/lib/modules/               # dm-verity and dm-crypt kernel modules (if not built-in)
```

Target size: ~5-10MB compressed. All binaries statically linked against musl.

**Build note**: Statically linking `veritysetup` and `cryptsetup` (which depend on `libdevmapper` and `libcryptsetup`) is non-trivial. Alpine Linux packages provide musl-linked static builds that can be extracted directly. Alternatively, build from source with `--enable-static --disable-shared` against musl-libc.

## Estimated Boot Latency

| Phase | Duration | Notes |
|-------|----------|-------|
| CH kernel + initramfs load | ~200ms | Existing |
| dm-verity signature verify | ~10ms | ED25519 + ML-DSA-87 verify |
| dm-verity activation | ~50ms | Device mapper setup, no I/O yet |
| dm-verity base OS mount | ~100ms | First reads verify Merkle path |
| Iroh key injection | 200-500ms | QUIC handshake + E2E key delivery from user device |
| DEK recryption + delivery | ~50ms | Host recrypts, delivers via vsock |
| LUKS open | ~50ms | Raw key injection (no PBKDF — much faster than Argon2id) |
| Overlay setup + pivot_root | ~50ms | overlayfs + bind mounts |
| **Total added** | **~500-800ms** | Over current ~2-3s boot |

Expected total boot time: ~2.5-3.8 seconds for a fully verified, encrypted boot.

## Counterfactuals and Trade-offs

### 1. dm-verity Requires a Block Device

dm-verity cannot protect a virtio-fs directory share. The base OS must be an ext4 image served via virtio-blk. This means CH needs both `"disks"` (base OS) and `"fs"` (userdata) entries. Cloud Hypervisor supports mixing storage backends, so this is configuration, not a limitation.

The BTRFS subvolume approach remains for userdata where CoW snapshots matter. The base OS doesn't need CoW — it's immutable.

### 2. User Must Be Online for Primary Path

The user-device-generated ephemeral keypair (primary path) requires the user to be online during VM spawn to inject the private key via Iroh. This is acceptable for interactive use. For autonomous spawning (dormant restoration, scaling), the pre-committed key pool (offline path) provides a fallback with a slightly weaker trust model.

### 3. Offline Boot

If the Identikey user is unreachable AND the recryption proxy is down AND no pre-committed keys are available, the VM cannot unlock its userdata. This is by design — it's the zero-knowledge property. The initramfs should:

- Retry with exponential backoff (5s, 10s, 20s...)
- Display status on the PTY console: "Waiting for key provider..."
- After timeout (configurable, default 60s): drop to a minimal shell for debugging, with no access to encrypted data

### 4. Signing Key Trust

The boot image signing key is a single point of trust. Whoever holds it can produce a malicious initramfs that exfiltrates LUKS keys. Mitigations:

- **Hardware-backed key**: Store signing key on YubiKey or HSM
- **Multi-party signing**: Require 2-of-N threshold signatures
- **Transparency log**: Publish signed boot image hashes to an append-only log

### 5. Rollback Protection

dm-verity alone doesn't prevent booting an older (potentially vulnerable) base OS image. For rollback protection:

- Include a monotonic version counter in the signed manifest
- The initramfs checks the counter against a stored minimum (in LUKS header metadata or a TPM-like counter)
- Refuse to boot if the version is below the minimum

## Implementation Phases

### Phase A: Minimal Initramfs Boot (No Encryption, No Verification)

Prove the boot chain works:
1. Build minimal initramfs with busybox + `/init` script
2. Add `initramfs_path` to CH config, update `kernel_payload/1`
3. initramfs mounts virtio-fs and does `pivot_root` (same as today, but via initramfs)
4. Verify PTY console works during initramfs phase via `mjolnir-boot-agent` (vsock only, no Iroh)

**Note**: Phase A skips signature verification and dm-verity. The init script is a simplified version that just mounts and pivots.

### Phase B: dm-verity Base OS

Add integrity verification:
1. Build ext4 base OS image from existing BTRFS subvolume
2. Generate dm-verity hash tree with `veritysetup format`
3. Add `base_os_image` and `disk_config/1` to CH config for virtio-blk
4. Update virtiofsd scope: `shared_dir` now points to userdata-only subvolume
5. initramfs activates dm-verity, mounts verified base, sets up overlayfs
6. virtio-fs now serves only the userdata subvolume

### Phase C: LUKS Encrypted Userdata (Direct DEK via Iroh)

Add encryption with the simplest key injection (no PRE yet):
1. Create LUKS-formatted userdata volume at VM spawn (`cryptsetup luksFormat --cipher aes-xts-plain64 --key-size 512 --key-file <random_dek>`)
2. Extend `mjolnir-boot-agent` with Iroh endpoint for INJECT_ALPN
3. User device unwraps DEK locally, delivers raw DEK via Iroh (E2E)
4. initramfs receives DEK, opens LUKS, assembles overlay, pivots
5. Establish agent handoff: boot-agent writes Iroh key, full agent picks it up

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
2. Boot image build script (`scripts/build-boot-image.sh`)
3. Manifest generation and verification
4. Init script signature verification (ED25519 + ML-DSA-87 dual check before trusting roothash)
5. Remote attestation: client verifies guest dm-verity hash before key delivery
6. Key management (generation, rotation, multi-party)

## References

### Mjolnir
- `lib/mjolnir/cloud_hypervisor/config.ex` — Current CH config (to be extended)
- `lib/mjolnir/cloud_hypervisor/client.ex` — CH API client
- `lib/mjolnir/vm.ex` — VM lifecycle GenServer
- `lib/mjolnir/virtiofs.ex` — Current virtiofsd management (scope changes in Phase B)
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
