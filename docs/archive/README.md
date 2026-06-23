# Archived docs

Documents in this directory describe **superseded designs** that no longer match how Mjolnir
works today. They're kept for historical context — to explain *why* the architecture evolved —
but should **not** be used as a guide to the current system.

If you're an agent or a newcomer: prefer the docs in [`../`](../) and the user
[Guide](../guide/). Treat anything here as "how it used to be."

## Contents

- **[storage-architecture.md](storage-architecture.md)** — the original ext4-on-BTRFS /
  Firecracker-era storage model (block-device images on BTRFS, cloned with `cp --reflink`).
  Mjolnir now uses Cloud Hypervisor v50 + virtio-fs with BTRFS subvolumes (cloned with
  `btrfs subvolume snapshot`, no ext4 images). The CoW reasoning and the Phase 3/4
  content-addressed-storage trajectory in that doc are still conceptually relevant; the ext4
  mechanics are not. For the current storage story see
  [`../guide/coming-from-docker.md`](../guide/coming-from-docker.md) and
  `../encryption-and-security.md`.
