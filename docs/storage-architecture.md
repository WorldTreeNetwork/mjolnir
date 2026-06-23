# Storage Architecture — moved

> **This document has been archived.** It described the original ext4-on-BTRFS / Firecracker-era
> storage model, which Mjolnir no longer uses. It now lives at
> [`archive/storage-architecture.md`](archive/storage-architecture.md).
>
> For the **current** storage design (Cloud Hypervisor v50 + virtio-fs + BTRFS subvolumes,
> cloned via `btrfs subvolume snapshot`), see:
> - [`guide/coming-from-docker.md`](guide/coming-from-docker.md) — the CoW / reflink / snapshot
>   story in plain terms
> - `encryption-and-security.md` — the current three-tier storage model
> - `architecture.md` — the module-level architecture
