# H3: Confidential Computing (SEV-SNP/TDX) Requirements

## Summary

Confidential computing (SEV-SNP/TDX) is **necessary for true zero-knowledge runtime** but **not sufficient alone**, and Mjolnir's current virtio-fs architecture is **fundamentally incompatible** with confidential computing's trust model. However, a pragmatic "encrypted at rest, trusted during runtime" model provides meaningful value today and establishes a credible migration path.

## Evidence

### What a Malicious/Curious Hypervisor Can See Today

Mjolnir's current architecture gives the host **total omnipotence** through five channels:

1. **Filesystem (virtio-fs)**: virtiofsd runs on host with `--shared-dir` and `--sandbox=none` (`virtiofs.ex:91-96`). Full read/write access to every guest file.

2. **Memory**: `"shared" => true` in memory config (`config.ex:94-98`), required for virtio-fs. Guest RAM is mapped into host address space. Host can read `/proc/<ch-pid>/mem`.

3. **vsock**: All control messages are plaintext JSON (`protocol.ex:25-36`). Host mediates every byte.

4. **Boot-time secrets**: SSH keys, identity, Iroh config all sent plaintext over vsock (`protocol.ex:94-136`).

5. **Process control**: Hypervisor is an Erlang Port — host has full lifecycle control.

### What AMD SEV-SNP Provides

- **Memory encryption**: Guest pages encrypted with per-VM AES key managed by AMD Secure Processor
- **Integrity protection**: Per-page authentication prevents replay, remapping, tampering
- **Register state protection**: Guest CPU registers encrypted (SEV-ES)
- **Remote attestation**: Guest proves to remote party it's running genuine SEV-SNP

**Critical limitation**: SEV-SNP protects RAM but **NOT I/O channels**. DMA goes through shared bounce buffers (SWIOTLB). Virtio devices operate on shared memory. This means:
- virtio-fs data passes through shared memory — **host can read it**
- vsock data passes through hypervisor — **host can read it**

### Cloud Hypervisor Support Status

- **TDX**: Experimental support exists. Requires Intel 4th Gen Xeon (Sapphire Rapids+).
- **SEV-SNP on KVM**: Active development (issue #6653). **Not yet production-ready.**
- **SEV-SNP on MSHV**: More mature, uses IGVM format. Behind `sev_snp` feature flag.

### The virtio-fs vs virtio-blk Tension

This is the **core architectural decision** for zero-knowledge:

| Approach | Host Sees FS? | CCC Compatible? | Snapshot Speed | Current? |
|----------|--------------|-----------------|---------------|----------|
| virtio-fs (current) | Yes (virtiofsd) | No | Instant (BTRFS reflink) | Yes |
| virtio-blk + dm-crypt | No (encrypted block) | Yes (SEV protects key in RAM) | Slower (image copy) | No |
| virtio-fs + fscrypt | Encrypted content | Partial (metadata visible) | Instant | No |

**fscrypt on virtio-fs**: Does NOT work. fscrypt requires ext4/f2fs/UBIFS. virtiofs passes through to host filesystem; it's not an independent FS that supports encryption policies.

### The Pragmatic Tier Model

**Tier 1: Encrypted at rest (achievable now)**
- Encrypt btrfs send streams and dormant snapshots
- Threat model: "honest-but-curious server at rest, trusted during runtime"
- Protects dormant VM data, snapshot archives, backup transfers
- Does NOT protect running VM memory or active I/O

**Tier 2: Encrypted communication channels (achievable now)**
- TLS/noise protocol on vsock channel (encrypt control messages)
- Iroh direct connections already use QUIC with encryption
- Protects control plane secrets, command execution content

**Tier 3: Confidential computing runtime (requires hardware + arch change)**
- SEV-SNP or TDX for memory protection
- Switch from virtio-fs to virtio-blk + dm-crypt
- Remote attestation for secret injection (key never passes through host)
- Protects everything except I/O metadata (timing, sizes)

## Confidence

**High for the analysis; Medium for Tier 3 timeline.** The architectural constraints are clear and well-documented. The main uncertainty is when Cloud Hypervisor's SEV-SNP on KVM will be production-ready — this gates the Tier 3 timeline.

## Sources

- `lib/mjolnir/virtiofs.ex:91-96` — virtiofsd with `--sandbox=none`, full shared-dir access
- `lib/mjolnir/cloud_hypervisor/config.ex:94-98` — `"shared" => true` memory config
- `lib/mjolnir/cloud_hypervisor/config.ex:107-114` — fs_config exposing rootfs
- `lib/mjolnir/vsock/protocol.ex:94-136` — plaintext secret injection
- [CH SEV-SNP KVM issue #6653](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/6653)
- [CH TDX docs](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/intel_tdx.md)
- [Linux fscrypt docs](https://docs.kernel.org/filesystems/fscrypt.html) — supported FS list (no virtiofs)

## Open Questions

1. **When will CH SEV-SNP on KVM be production-ready?** Active development but no ETA. This is the gate for Tier 3.

2. **Is the BTRFS reflink speed loss acceptable?** Moving to virtio-blk + dm-crypt loses instant CoW cloning. Is sub-second snapshot creation worth the privacy trade-off? Or can btrfs send/receive of encrypted streams substitute?

3. **Hybrid model**: Could we use virtio-fs for the generic OS layer (unencrypted, shared base) + virtio-blk for user data (encrypted, per-VM)? Two storage paths add complexity but preserve speed for boot while protecting sensitive data.

4. **Remote attestation flow**: How does the client verify the guest is running genuine SEV-SNP before injecting the DEK? This is a whole protocol (AMD attestation report → client verification → sealed secret injection). Needs detailed design when Tier 3 is in scope.
