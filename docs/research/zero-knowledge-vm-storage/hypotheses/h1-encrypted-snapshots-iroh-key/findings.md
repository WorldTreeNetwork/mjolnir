# H1: Encrypt-at-Snapshot with Client-Held DEK, Inject via Iroh

## Summary

Architecturally feasible within Mjolnir's current design, but with a fundamental tension: the server sees plaintext during VM runtime regardless (virtio-fs gives the host full filesystem access). The security guarantee is limited to "snapshots at rest are opaque to the server." The Iroh P2P channel is a genuine advantage for DEK injection since it bypasses the host-controlled vsock, but decrypting at boot requires solving a chicken-and-egg problem.

## Evidence

### Snapshot Encryption Flow

The current snapshot path (`vm.ex:1214-1255`) runs `sync` inside the guest, pauses via hypervisor API, then does `btrfs subvolume snapshot` — an atomic CoW clone. The snapshot is a plaintext directory tree.

**The core problem**: The server executes the snapshot. The guest cannot encrypt its own filesystem in-place because:
- The rootfs is mounted via virtio-fs — the underlying storage is a host-side BTRFS subvolume
- `btrfs subvolume snapshot` operates on the host side, not anything the guest controls
- Even if the guest encrypted files individually, directory structure and metadata remain visible

**Two viable approaches**:

**Approach A — Server-assisted encryption (server sees DEK transiently)**: Client sends DEK to server. Server snapshots, pipes `btrfs send` through streaming cipher, stores only ciphertext, zeroes DEK from memory. Server sees DEK briefly.

**Approach B — Guest-side encryption before snapshot**: Guest agent encrypts sensitive state into an encrypted archive before signaling done. Snapshot contains encrypted blob + minimal OS skeleton. More robust but OS files remain visible.

### Key Injection via Iroh

The guest runs an Iroh endpoint with its own Ed25519 keypair (`iroh.rs:20-69`). Connections use direct QUIC via Iroh relays — **the host has no visibility into this traffic**.

A new ALPN (`mjolnir-key-inject/1`) alongside existing shell/tcp-fwd ALPNs would let the client inject the DEK directly into the running VM. The host cannot intercept because:
- Iroh uses QUIC with TLS 1.3, endpoint-to-endpoint encrypted
- The host does not hold the guest's Iroh secret key
- Vsock and Iroh are separate channels

**Caveat**: The host receives the Iroh ticket via vsock (`IrohReady` message). With capability-token auth on Iroh connections (rbac-design.md Phase 2), the guest would reject host connections without a valid Biscuit.

### Boot-Time Decryption — The Hard Problem

If the snapshot is encrypted, the server can't `btrfs receive` without the DEK. But the guest needs a booted OS to run Iroh to receive the DEK.

**Option 3a — Server decrypts at boot (simplest)**: Client sends DEK to server API. Server decrypts into plaintext subvolume, boots VM, forgets DEK. Server sees plaintext during runtime. Guarantee: dormant snapshots are encrypted.

**Option 3b — Two-phase boot with initrd (strongest non-TEE)**: Minimal initrd (kernel + busybox + Iroh client stub) boots first. Not encrypted — generic bootstrap. Waits for client DEK via Iroh, decrypts real rootfs via dm-crypt, pivots root. Server never sees plaintext rootfs. Requires custom initrd with Iroh compiled in.

**Option 3c — Encrypted overlay (best balance)**: Base OS boots normally from unencrypted generic rootfs. User-specific data lives in a LUKS volume on the virtio-fs mount. After Iroh DEK injection, guest mounts encrypted overlay. Only user data is protected, not the OS. Simpler than 3b, probably sufficient.

### Trust Model

| Threat | Protection |
|--------|-----------|
| Storage-level breach (disk theft) | Strong — encrypted snapshots |
| Curious operator browsing files | Strong at rest / None at runtime |
| Compromised server reading memory | None — hypervisor has full RAM access |
| MITM on snapshot transfer | Strong — encrypted stream + Iroh |
| Malicious hypervisor | None without TEE |

## Confidence

**Medium-High.** Architectural feasibility is clear and grounded in specific code paths. Main uncertainty is Option 3b (custom initrd), which requires significant new infrastructure. The recommended path (3a → 3c) is well within reach.

## Sources

- `lib/mjolnir/vm.ex:1214-1255` — `do_snapshot/3`: current snapshot flow
- `lib/mjolnir/vm.ex:538-552` — `handle_done`: dormant transition
- `lib/mjolnir/vm.ex:951-971` — `clone_rootfs/3`: boot-time clone
- `lib/mjolnir/btrfs.ex:80-113` — `create_snapshot/3`: snapshot with metadata
- `lib/mjolnir/virtiofs.ex:66-124` — virtiofsd lifecycle
- `native/mjolnir_guest_agent/src/iroh.rs:20-69` — Iroh endpoint setup
- `native/mjolnir_guest_agent/src/protocol.rs:194-212` — IrohReady notification
- `docs/plans/rbac-design.md:316-319` — Phase 2: Biscuit auth on Iroh

## Open Questions

1. Should we encrypt the `btrfs send` stream as a whole, or individual files within the subvolume?
2. DEK rotation: new DEK on every dormant cycle, or reuse? Reuse risks chain compromise.
3. Key escrow / recovery if user loses DEK — acceptable data loss? Shamir sharing?
4. Biscuit auth on Iroh is a **prerequisite** — without it, the host can connect to the guest's Iroh endpoint and intercept DEK injection.
5. Performance of encrypted btrfs send on multi-GB subvolumes needs benchmarking.
