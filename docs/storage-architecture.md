# Storage Architecture

> **Superseded:** This document describes the original ext4-on-BTRFS / Firecracker-era storage model. Mjolnir now uses Cloud Hypervisor v50 + virtio-fs with BTRFS subvolumes (no ext4 images). For the current architecture, see `docs/encryption-and-security.md` (three-tier storage model) and `docs/plans/initramfs-verified-boot.md` (verified boot design). This document is retained for historical context.

## 1. Original Architecture: ext4-on-BTRFS

Firecracker requires block device images (ext4 files). Mjolnir stores these on a BTRFS host filesystem to leverage copy-on-write reflink cloning.

**Key properties:**
- **Sparse files**: 8GB virtual size, only actual writes consume disk
- **BTRFS zstd compression**: ~40% savings on image files
- **Reflink copies**: Instant (metadata-only, ~1ms), regardless of image size
- **Storage layout**:
  ```
  /var/lib/mjolnir/btrfs/
  ├── @base/
  │   └── debian-12.ext4           (8GB sparse template)
  ├── @vms/{vm_id}/
  │   └── rootfs.ext4              (per-VM clone)
  └── @snapshots/
      ├── my-node-env.ext4         (reflink copy of a VM's rootfs)
      └── my-node-env.json         (metadata)
  ```

## 2. Why ext4 Image Files

Firecracker only supports **virtio-blk** (block devices). It cannot mount host directories, shared filesystems, or overlay mounts into the guest. The VM must boot from a disk image file. We use ext4 because it's the standard Linux filesystem, well-tested with Firecracker, and supports online resize.

This is the fundamental architectural constraint that shapes everything below. The ext4 image is an opaque blob from the host's perspective — BTRFS, S3, rsync, and content-addressed storage all see a single large file, not the individual files inside the VM.

## 3. Working with Sparse Images

ext4 images are created as sparse files: an 8GB image with 500MB of actual data only consumes ~500MB on disk. The "holes" (unwritten regions) take zero space.

### Inspecting actual disk usage

```bash
# Virtual size (what 'ls -l' shows) — misleading
ls -lh node-env.ext4
# -rw-r--r-- 1 root root 8.0G Feb 12 05:43 node-env.ext4

# Actual disk usage (blocks allocated)
du -h node-env.ext4
# 487M    node-env.ext4

# Both at once
du -h --apparent-size node-env.ext4   # 8.0G (virtual)
du -h node-env.ext4                    # 487M (actual)

# Full detail via stat
stat node-env.ext4
# Size: 8589934592   Blocks: 995328   (512-byte blocks = ~487MB actual)
```

### Shared vs exclusive blocks (BTRFS reflinks)

After a reflink copy, `du` shows the total blocks referenced by the file, including blocks shared with other files. To see what's actually unique:

```bash
btrfs filesystem du @base/debian-12.ext4 @snapshots/node-env.ext4 @vms/*/rootfs.ext4
```

This shows three columns:
- **Total** — all data referenced by the file
- **Exclusive** — blocks unique to this file (the actual extra disk cost)
- **Shared** — blocks shared with other files via reflink CoW

### Transferring sparse images off-host

When copying a sparse image to another machine, S3, or a backup, standard tools will expand the holes into real zeros — turning a 500MB file into 8GB on the wire. Use sparse-aware tools:

**rsync** (best for host-to-host):
```bash
rsync --sparse --progress node-env.ext4 remote:/path/
# Only transfers non-hole regions. Recreates holes on destination.
# Also supports --inplace for incremental updates to an existing copy.
```

**tar** (best for archival/S3):
```bash
tar cSf node-env.tar node-env.ext4    # -S = handle sparse files
# Resulting tar is ~actual data size, not 8GB.
# Extract with: tar xSf node-env.tar
```

**scp/sftp**: No sparse support. Avoid for large images — they'll transfer all 8GB.

**cp** (local): `cp --sparse=always` forces hole detection. `cp --reflink=auto` is even better on the same BTRFS filesystem (instant, zero copy).

### Re-sparsifying after guest activity

When files are deleted inside a VM, ext4 marks blocks as free but the sparse file doesn't shrink (see TRIM limitation below). To reclaim space:

```bash
# Inside the guest:
fstrim -v /                           # Zeros freed blocks

# On the host:
fallocate --dig-holes rootfs.ext4     # Punches holes where zeros exist
```

## 4. The TRIM/Discard Limitation

**Firecracker does NOT support TRIM/discard on virtio-blk.** This is the single biggest storage constraint:

- When files are deleted inside a VM, ext4 marks blocks as free internally
- But the backing sparse file on the host does NOT shrink — those blocks remain allocated
- A VM that installs 2GB of packages, then removes them, still uses 2GB on disk
- This affects ALL storage backends equally — it's a Firecracker limitation, not a BTRFS one

**Mitigation (before snapshotting):**
1. Inside guest: `fstrim -v /` — tells ext4 to TRIM freed blocks, which zeros them
2. On host: `fallocate --dig-holes <rootfs.ext4>` — punches holes where zeros exist, re-sparsifying the file
3. Result: freed space inside guest → actual freed space on host

**Future**: If Firecracker adds virtio-blk discard support, this becomes automatic. Track upstream.

## 5. Alternatives Considered

| Approach | Verdict | Why |
|----------|---------|-----|
| **OverlayFS + Squashfs base** | Best Phase 2 option | Shared read-only compressed base across ALL VMs. Per-VM writable overlay starts at 0 bytes. E2B uses in production. Two-drive Firecracker config + custom overlay-init in guest. |
| **ZFS zvol** | Strong but impractical | Instant clones, send/receive migration, checksums. But CDDL/GPL licensing conflict, not in mainline kernel, higher memory overhead. |
| **dm-thin provisioning** | Rejected | Block-level CoW. Docker deprecated it. Declining upstream. Complex setup. |
| **BTRFS-on-BTRFS** | Rejected | Kata Containers rejected for stability. No advantage without TRIM. Nested BTRFS complexity. |
| **BTRFS subvolume snapshots** | N/A for Firecracker | Firecracker needs file images, not mounted subvolumes. We use BTRFS reflinks on files instead. |

## 6. Parallel VMs from the Same Snapshot

BTRFS reflinks enable instant, independent CoW clones from any snapshot:

```
@snapshots/my-node-env.ext4  (the snapshot — never modified)
    ├── reflink → @vms/vm-001/rootfs.ext4  (VM 1: independent CoW copy)
    ├── reflink → @vms/vm-002/rootfs.ext4  (VM 2: independent CoW copy)
    ├── reflink → @vms/vm-003/rootfs.ext4  (VM 3: independent CoW copy)
    └── reflink → @vms/vm-NNN/rootfs.ext4  (VM N: independent CoW copy)
```

Properties:
- **Instant**: Each clone is a metadata operation (~1ms), regardless of image size
- **Independent**: Writes in VM-001 don't affect VM-002 or the snapshot
- **Space-efficient**: Only divergent blocks consume additional disk. 100 VMs from the same snapshot with identical base content ≈ 1x storage, not 100x
- **No coordination needed**: Reflinks are atomic. Hundreds of VMs can be spawned concurrently from the same snapshot without locking
- **Snapshot immutability**: The snapshot `.ext4` file is never written to — only cloned from. It can serve unlimited concurrent clones safely.

This is the same mechanism used for spawning from `@base/` images today. Snapshots are just user-created base images.

## 7. Space Efficiency Example

```
Scenario: 50 VMs spawned from "my-node-env" snapshot (2GB actual data in 8GB sparse image)

Without CoW:  50 × 2GB = 100GB disk usage
With reflinks: 2GB shared + divergent writes only

If each VM writes ~100MB of unique data:
  Actual usage: 2GB (shared) + 50 × 100MB (unique) = 7GB
  Savings: 93%
```

## 8. Snapshot Consistency Model

Snapshots use a hybrid approach for consistency:

| Step | Action | Why |
|------|--------|-----|
| 1 | `exec("sync")` inside guest | Flushes guest page cache → virtio-blk → host page cache |
| 2 | Firecracker `PATCH /vm {"state":"Paused"}` | Stops all further writes. <100ms. |
| 3 | Host-side `File.open(rootfs) + :file.sync` | Flushes host page cache → BTRFS on-disk |
| 4 | `cp --reflink` | Instant CoW copy of the flushed, quiesced image |
| 5 | Firecracker `PATCH /vm {"state":"Resumed"}` | VM resumes. Always runs (try/after). |

This is strictly better than either approach alone:
- Faster than fsfreeze (no journal flush wait)
- More consistent than pause alone (guest sync + host fsync covers all caches)
- Simpler error handling (resume is always safe, unlike fsfreeze -u)
- Enables future full-state memory+CPU snapshots via Firecracker's native snapshot API

## 9. Evolution Path: From ext4 Images to Content-Addressed Storage

### Phase 1 (now): ext4-on-BTRFS with reflinks

Simple, proven, good enough for single-host operation. BTRFS provides instant cloning and space efficiency. The ext4 image approach works well when all VMs live on one machine.

### Phase 2: OverlayFS + Squashfs read-only base

When scaling to 100+ concurrent VMs. A compressed, read-only squashfs base image is shared across all VMs with per-VM writable overlays. Eliminates even the reflink overhead for the base layer.

### Phase 3: Content-addressed storage via Iroh/BLAKE3

This is where the ext4 image approach hits its limits.

**The problem with ext4 images for cross-host sync:**

The ext4 image is an opaque blob. Content-addressed storage (Iroh/BLAKE3) works by splitting data into chunks, hashing each chunk, and only transferring/storing unique chunks. With ext4 images:

- **Poor chunk alignment**: Identical files inside two VMs may sit at different block offsets in the ext4 layout. Content-defined chunking (CDC) sees different byte sequences and fails to deduplicate.
- **Metadata churn**: ext4 journals, timestamps, and superblock updates cause chunks to diverge even when the actual user data is identical.
- **Dead data in transit**: Without TRIM support, deleted files inside the VM still exist as allocated blocks in the image. These get chunked, hashed, and transferred unnecessarily.
- **No file-level granularity**: You can't sync a single file from inside the VM — you have to chunk and diff the entire multi-gigabyte image.

In contrast, if the storage layer had direct access to the VM's filesystem tree (individual files and directories), content-addressing would work naturally: each file gets chunked and hashed independently, identical files across VMs deduplicate perfectly, and only actual file changes need to be transferred between hosts.

**This is the inflection point**: ext4 images work great on a single host (BTRFS handles everything). They become a burden when crossing host boundaries, because you're forced to treat a rich filesystem as a flat byte stream.

### Phase 4: Hypervisor evolution — virtio-fs

The ext4 image requirement comes from Firecracker's virtio-blk-only constraint. **Cloud Hypervisor** (also written in Rust, similar security model) supports **virtio-fs**, which lets the VM mount a host directory directly as its filesystem:

```
Iroh content-addressed store (host)
  └── virtio-fs mount → /  (guest sees files directly, no ext4 image)
```

With virtio-fs:
- No ext4 image files at all
- Content-addressing operates on individual files
- Changes inside the VM are immediately visible on the host
- Cross-host sync transfers only changed files/chunks
- No TRIM problem (there's no block device layer to leak through)

**Cloud Hypervisor** is the most likely candidate:
- Rust, minimal attack surface (similar philosophy to Firecracker)
- Actively maintained by Intel/ARM, used in Kata Containers
- Supports virtio-fs, virtio-blk, vhost-user, and more
- Boot times comparable to Firecracker (<200ms)
- API-driven (REST over Unix socket, like Firecracker)

The Mjolnir orchestration layer (OTP supervision tree, networking, API, snapshot semantics) is hypervisor-agnostic. Swapping Firecracker for Cloud Hypervisor would primarily affect `Mjolnir.Firecracker.Client`, `Mjolnir.Firecracker.Config`, and the boot sequence in `Mjolnir.VM.do_boot/1`.

### Other options on the table for Phase 3+

| Option | Strengths | Considerations |
|--------|-----------|----------------|
| **Cloud Hypervisor + virtio-fs** | Best path to content-addressed storage. Rust, minimal, fast. Direct filesystem access eliminates ext4 overhead. | Slightly larger than Firecracker. Less battle-tested at Lambda scale. |
| **Firecracker + virtiofs (if added)** | Would solve everything without switching hypervisors. | No upstream plans to add it. Firecracker's design philosophy is minimal surface area. Unlikely. |
| **QEMU/KVM + virtio-fs** | Most flexible. Supports every storage backend imaginable. | Larger attack surface. Heavier. More configuration complexity. |
| **casync / desync** | Content-defined chunking for disk images. Can efficiently sync ext4 images without virtio-fs. | Still operating on opaque blobs. Better than rsync, worse than native file-level content-addressing. Could be a pragmatic bridge. |
| **Iroh + FUSE** | Content-addressed FUSE filesystem on host, mounted into VM via virtio-fs. Full dedup, cross-host sync, no images. | Adds FUSE latency. Need to benchmark. Iroh is still evolving. |

### Summary: when each layer matters

```
Single host, few VMs     → ext4-on-BTRFS is perfect (Phase 1)
Single host, many VMs    → OverlayFS + Squashfs base (Phase 2)
Multi-host sync needed   → ext4 images become the bottleneck (Phase 3)
Multi-host + dedup       → virtio-fs + content-addressed store (Phase 4)
```

BTRFS serves us well for Phase 1-2. The investment isn't wasted — the orchestration, networking, and snapshot semantics all carry forward. The storage layer is the part that evolves.
