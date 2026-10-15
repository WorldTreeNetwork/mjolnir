# Threat Model

What Mjolnir protects against, what it doesn't, and what's on the roadmap.

> **See also:** `docs/encryption-and-security.md` for the three-tier storage
> model and encryption layer design, `docs/secrets-architecture.md` for the
> LUKS2 injection protocol.

## Assumptions

1. **The host is still the trusted computing base.** The kernel, the
   hypervisor, and the BEAM can read guest memory, guest disks, and
   vsock. A capability token does not change that. Confidential
   computing (SEV-SNP / TDX) is the only thing that would, and it is
   not this system.

2. **Guests are hostile.** They have code we did not write, they can
   open sockets, and they will be able to message each other and take
   actions. "Buggy but not malicious" is not the model.

3. **A place is not a principal.** A TCP connection to `127.0.0.1` is
   not the operator. The public gateway dials loopback for site
   fallback. The operator is the Unix socket at
   `/run/mjolnir/operator.sock` (mode `0600`). Automation is a Biscuit
   delegated to one repo and one operation. A human `mj` session is
   that human's token `sub`.

4. **The network is untrusted.** Guest-to-guest forwarding is denied.
   External hops use TLS or QUIC. The host still sees metadata.

5. **Physical access is out of scope.** Disk encryption of the host
   partition is a deployment concern, not a Mjolnir feature.

## What's Protected

### Against external attackers (internet-facing)

| Attack | Protection |
|---|---|
| Traffic interception | QUIC/TLS 1.3 (Iroh), HTTPS (gateway) |
| Unauthorized VM access | ED25519 peer identity (Iroh), JWT + ownership policy (API) |
| Secret theft in transit | LUKS passphrase injected over Iroh QUIC (end-to-end encrypted) |
| DNS hijacking of VM URLs | TLS certificate pinned to `*.vm.worldtree.network` |
| API bruteforce | Public `:4000` is firewalled. `api.vm.worldtree.network` is the gateway, token-authenticated. Peer address grants nothing |

### Against guest escape (VM → host)

| Attack | Protection |
|---|---|
| Filesystem escape | BTRFS subvolume-per-VM; virtio-fs enforces share boundary |
| Network escape | Dedicated TAP per VM. FORWARD from the guest subnet to itself is dropped. Sidecars on `10.200.0.1` are a separate allow |
| vsock impersonation | Hypervisor-enforced CID isolation (unique per VM) |
| Device access | `DeviceAllow` restricts to `/dev/kvm` and `/dev/net/tun` only |
| Kernel exploit | Cloud Hypervisor is a minimal VMM (Rust, small attack surface) |

### Against configuration drift (ops mistakes)

| Attack | Protection |
|---|---|
| Unit file tampering | Forge tracks `mjolnir.service` with three-way diff; drift detected on next `forge-plan` |
| Accidental privilege escalation | `ProtectSystem=strict` prevents writing to `/usr`, `/boot`, system binaries |
| Stale orphan processes | `Mjolnir.Cleanup` sweeps on every boot |
| Service crash | `Restart=always` + `Reconcile` rehydrates VMs from StateStore |

### Against cross-user interference (multi-tenant API)

| Attack | Protection |
|---|---|
| Access another user's VM | `Mjolnir.Policy.VM` enforces `owner_id` match from JWT `sub` |
| Snapshot another user's VM | `Mjolnir.Policy.Snapshot` enforces ownership |
| Domain hijack | `SecretStore` alias index prevents cross-IdentiKey overwrites |
| Path traversal | Safe name validation (`[a-zA-Z0-9._-]`, no `..`) on all user-supplied paths |

## What's NOT Protected

### Host compromise

If an attacker gains root on the host, they can:
- Read all VM memory (via `/proc/<pid>/mem` or hypervisor debug)
- Read all BTRFS subvolumes (plain filesystem access)
- Intercept vsock traffic (kernel-mediated, unencrypted)
- Inject a compromised guest agent into new VMs

**Mitigation path**: The zero-knowledge architecture
(`docs/encryption-and-security.md`) designs for encrypted snapshots
(XChaCha20-Poly1305) and encrypted runtime (LUKS overlay). Phase 1-3
protect data at rest; Phase 6 (confidential computing with SEV-SNP/TDX)
would protect runtime.

### Cross-VM network attacks

`Mjolnir.Network.ensure_guest_isolation/1` inserts a FORWARD drop for
the guest subnet to itself, with an accept for the host sidecar
address in front of it. Guests can still reach the host sidecars
(Postgres, Redis, the blob door) and the public internet, and they
share the host's egress address. Iroh is a second path that does not
cross that FORWARD rule. A per-pair allow, installed by the host
because a capability names it, is the next step. It is not built.

### Guest agent integrity

The guest agent binary is copied into the rootfs at boot without integrity
verification (no SHA256 check, no signature). A compromised host could
inject a malicious agent.

**Mitigation path**: Sign the agent binary; verify signature inside the
guest initramfs before exec. The initramfs boot chain
(`docs/encryption-and-security.md` Tier 1) is designed for this.

### Snapshot secret leakage

Snapshots capture the full rootfs including SSH keys, Iroh node keys, and
any application secrets written to disk. Cloning a snapshot gives the new
VM access to the original's identity.

**Mitigation**: `preserve_iroh_key: false` regenerates the Iroh key on
clone. SSH key and application secret rotation is the user's
responsibility. The LUKS secrets volume (`docs/secrets-architecture.md`)
is designed to keep secrets out of the snapshotted rootfs — secrets live
in a separate encrypted partition that is not included in BTRFS snapshots.

## Cryptographic Primitives

| Primitive | Use | Library |
|---|---|---|
| ED25519 | Identity signing (IdentiKey), Iroh peer identity | OTP `:crypto`, Iroh |
| XChaCha20-Poly1305 | Envelope encryption (Sites), future snapshot encryption | Pure Elixir (`Mjolnir.Sites.Crypto`) |
| HKDF-SHA256 | Per-file key derivation from snapshot master seed | Pure Elixir |
| Blake3 | Content addressing (stub: currently SHA-256, Rust NIF planned) | Elixir fallback |
| LUKS2 (AES-XTS + Argon2id) | Secrets volume encryption inside guest | `cryptsetup` in guest |
| QUIC/TLS 1.3 | Iroh peer transport, gateway HTTPS | rustls |

## Security Roadmap

| Phase | What | Status |
|---|---|---|
| Host hardening (ProtectSystem=strict) | systemd filesystem + kernel protections | **Done** (2026-05-25) |
| Forge config reconciler | Drift detection for host configuration | **Done** (2026-05-25) |
| Secrets injection (LUKS2 + Iroh) | Zero-knowledge secret delivery to VMs | **Done** (design + implementation) |
| ED25519 signed sites | Authenticated HEAD + manifest publishing | **Done** (IdentiKey Sites) |
| Encrypted snapshots (XChaCha20) | Encrypt BTRFS snapshots at rest | Designed, not yet implemented |
| Proxy re-encryption (Recrypt) | Zero-knowledge snapshot sharing | Designed, not yet implemented |
| Encrypted runtime (LUKS overlay) | Protect VM data from host at runtime | Designed, not yet implemented |
| Guest agent signing | Integrity-verified agent injection | Not yet designed |
| Per-VM network isolation | nftables or netns per VM | Not yet designed |
| Confidential computing (SEV-SNP/TDX) | Hardware-enforced VM memory encryption | Future (hardware dependency) |
