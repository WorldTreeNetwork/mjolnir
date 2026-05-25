# Hardware Requirements

This document defines the hardware and host-OS requirements for running Mjolnir, with the reasoning behind each requirement. It also enumerates environments that are known *not* to work, so deployment attempts can fail fast rather than discovering blockers mid-bring-up.

Mjolnir has two viable deployment profiles. Most of this document covers the **full profile** (the default — microVMs spawned by Cloud Hypervisor with BTRFS storage and TAP networking). A second **OTP-only profile** is described in §7; it relaxes the hardware requirements significantly in exchange for giving up microVM isolation, and is intended for environments where the full profile is impossible (e.g. containerized GPU rentals).

---

## 1. CPU and Virtualization

### Hard requirements (full profile)

- **x86_64** (Intel or AMD). ARM64 is supported by Cloud Hypervisor upstream, but Mjolnir's guest agent and rootfs build pipeline target `x86_64-unknown-linux-musl` exclusively. ARM is not currently tested.
- **Hardware virtualization extensions**, exposed to the host kernel:
  - Intel: VT-x with EPT (Extended Page Tables)
  - AMD: AMD-V with NPT (Nested Page Tables)
- **`/dev/kvm`** must be present, readable, and writable by the user running the Elixir orchestrator.

### Why these are non-negotiable

Cloud Hypervisor is a KVM-only VMM. It is built on the `rust-vmm` crate ecosystem, which assumes a KVM backend; no software-emulation path exists.

There is no "emulate KVM in userspace" option that is useful for Mjolnir. The closest alternative — QEMU's TCG (Tiny Code Generator) backend — runs guest instructions in pure software at roughly 10–50× slower than native, and would require switching VMM entirely. For Mjolnir's design goals (sub-second VM boot, near-native compute throughput for workloads inside the guest) this is a non-starter.

Nested virtualization works (Mjolnir-on-KVM-on-KVM) provided the outer hypervisor exposes nested-virt extensions. Cloud providers vary; verify before committing.

### Verification

```bash
# Extensions visible to the kernel
grep -E 'vmx|svm' /proc/cpuinfo | head -1

# KVM module loaded
lsmod | grep kvm

# Device node accessible
ls -l /dev/kvm
# crw-rw---- 1 root kvm 10, 232 ...  ← the kvm group must include the orchestrator user
```

A passing host returns CPU flags and a `/dev/kvm` device node accessible by the user running `mjolnir`.

---

## 2. Memory and Disk

### Memory

- **Host RAM**: enough for the host OS (≥ 1 GB), plus the sum of microVM memory budgets, plus orchestrator overhead. Mjolnir's per-VM memory overhead is ~5 MB on top of whatever the guest requests.
- No specific minimum is enforced by Mjolnir, but a host below 4 GB is impractical once you account for BTRFS metadata caches and the BEAM VM.

### Disk

- **A BTRFS volume** mounted at the Mjolnir data root (default `/var/lib/mjolnir`). This is mandatory — see §3.
- **Free space** sufficient for the base rootfs image (a few hundred MB compressed, several GB unpacked) plus per-VM working space. Snapshots and clones are reflink-based and consume near-zero additional space until divergence.
- **NVMe SSD strongly preferred.** BTRFS reflink performance is excellent on any modern block device, but virtio-fs throughput into guests is bottlenecked by host random-IO. HDDs are technically supported and operationally painful.

---

## 3. Filesystem

### Required

- **BTRFS** at the Mjolnir data root, with the following features active:
  - **Subvolumes** (for per-VM and per-snapshot roots)
  - **Reflink copies** via `cp --reflink=always` or the equivalent ioctl (`FICLONE`)
  - **Compression** (`zstd` recommended) — optional, but typical for ext4-image-era deployments; current virtio-fs-on-BTRFS architecture benefits less but it's still harmless

The Cloud Hypervisor + virtio-fs architecture shares **BTRFS subvolumes** directly into the guest. There is no ext4 image file in the current model; snapshots are subvolume snapshots, not file clones. See `docs/encryption-and-security.md` for the three-tier storage model that supersedes the original ext4-on-BTRFS design.

### Why BTRFS specifically

The two properties Mjolnir hard-depends on are **subvolume snapshots** and **reflink** for instant-clone semantics. Filesystems that offer one but not the other (e.g. ZFS has snapshots, ext4 has neither) do not work without substantial reimplementation of the storage layer. XFS has reflink but no subvolume snapshot semantics; bcachefs is plausible long-term but not currently tested.

### Verification

```bash
# Filesystem type at the data root
findmnt -no FSTYPE /var/lib/mjolnir
# btrfs

# Reflink works
touch /var/lib/mjolnir/.reflink-test && cp --reflink=always /var/lib/mjolnir/.reflink-test /tmp/test.copy
echo $?   # 0 expected; non-zero indicates reflink not supported on this filesystem
rm /var/lib/mjolnir/.reflink-test /tmp/test.copy
```

---

## 4. Networking

### Required

- **Linux kernel with TAP device support** (`CONFIG_TUN=y` or as a loaded module). Standard on every distro kernel.
- **IP forwarding enabled**: `sysctl net.ipv4.ip_forward=1`.
- **iptables / nftables** for NAT egress from VMs. The orchestrator manages rules at `10.200.0.0/16` (per-VM TAPs).
- **vsock support** (`CONFIG_VHOST_VSOCK=y` or module). Used for host↔guest control-channel messaging from the orchestrator to the guest agent.

### Optional but recommended

- A network interface (or bridge) suitable for the host's egress. Mjolnir does not require a specific external NIC.
- A public IPv4 address is **not required** — Iroh-based access (NAT-traversing QUIC) is the default external reach for VMs. A reachable IP simplifies operations but isn't load-bearing.

### Verification

```bash
ls /sys/class/net/ | head           # at least lo, ens*, eth* expected
sysctl net.ipv4.ip_forward          # = 1
modprobe vhost_vsock && lsmod | grep vhost_vsock
```

---

## 5. GPU Workloads

Running GPU-bound workloads inside a Mjolnir microVM (e.g., CUDA inference, training) requires hardware passthrough. **This has strictly stricter requirements than non-GPU workloads** and is the single most common reason a host that "looks fine" can't host a GPU microVM.

### Required (for GPU microVMs)

- **IOMMU support enabled in firmware**:
  - Intel: VT-d enabled in BIOS/UEFI
  - AMD: AMD-Vi (IOMMU) enabled
- **Kernel boot arguments** to activate the IOMMU and ensure usable groups:
  - Intel: `intel_iommu=on iommu=pt`
  - AMD: `amd_iommu=on iommu=pt`
- **VFIO drivers** (`vfio`, `vfio_pci`, `vfio_iommu_type1`) available; the target GPU(s) must be rebindable from the vendor driver (e.g. `nvidia.ko`) to `vfio-pci`.
- The GPU must occupy an **IOMMU group that is isolatable** — i.e., not sharing a group with critical devices the host needs. ACS overrides may be required for consumer hardware; data-center cards (L40S, H100, A100) generally have clean groups.
- The host must be willing to **unbind the GPU from the vendor driver** before guest start. The host loses access to the GPU while it's assigned to a guest.

### Why this rules out most cloud-rented GPU environments

Containerized GPU rentals (RunPod, Vast.ai, most "serverless GPU" platforms) hand you the GPU via container device cgroups (`--gpus all` semantics). The tenant container does not control the host kernel, cannot enable the IOMMU, cannot unbind `nvidia.ko`, and cannot bind `vfio-pci`. Even if `/dev/kvm` were exposed to the container — which it usually isn't — the GPU cannot be passed through to a guest VM from inside that container.

The only environments where GPU passthrough works are ones where **you control the host kernel**. In practice that means:

- Bare-metal you own
- Bare-metal rentals from providers like Hetzner dedicated, OVH dedicated, Latitude.sh metal, Equinix Metal, Vultr Bare Metal (subject to GPU SKU availability — often constrained)
- Dedicated hosts on hyperscalers (e.g. EC2 `*.metal` instance types with attached GPU — extreme cost)

For users who need GPU compute *managed by Mjolnir* but can't acquire bare-metal: see §7 for the OTP-only deployment profile, which supervises GPU workloads as host-OS processes rather than as guest VMs.

---

## 6. Host OS

### Tested

- Debian 12 (bookworm) — primary deployment target
- Ubuntu 22.04 LTS, 24.04 LTS — known working

### Required components on the host

- **systemd** — the Mjolnir orchestrator is installed as a unit
- **BTRFS userspace tools** (`btrfs-progs`)
- **iproute2** (`ip`, `tc`) for TAP/route management
- **iptables-nft** or **nftables** for NAT rules
- A recent **Cloud Hypervisor** binary (currently v50.0)
- **Erlang/OTP** with the BEAM VM (provided via a packaged Elixir release; you don't need a system-wide Elixir install in production)

Distros not based on glibc (e.g. Alpine) are not currently supported as host OS due to Cloud Hypervisor's distribution model.

### Kernel version

Cloud Hypervisor v50 requires Linux ≥ 5.13 on the host for full virtio-fs feature support. Any current LTS kernel (≥ 6.1) is comfortably above this floor.

---

## 7. OTP-Only Deployment Profile

This profile is intended for environments where the full profile is structurally impossible — chiefly **containerized GPU rentals** where you can't access KVM, IOMMU, or BTRFS — but you still want Mjolnir's orchestration semantics (supervised lifecycle, structured failure recovery, distributed addressability via Iroh, unified HTTP API).

In this profile:

- **Cloud Hypervisor is not installed and not started.**
- **VM spawning is disabled** in the orchestrator config (`hypervisor: :none`).
- Workloads run as **host-OS processes managed by an OTP `Port`**, supervised by a `Mjolnir.Worker.Port` GenServer attached to the existing `DynamicSupervisor`.
- The HTTP API, JWT auth, telemetry, and Iroh endpoint remain unchanged — the orchestration surface looks identical to clients.

### What's preserved

- OTP supervision (crash → restart with configurable strategy)
- Structured logging, telemetry, observability
- Iroh-based NAT-traversing access to the orchestrator's HTTP API
- A consistent control plane across heterogeneous deployments (some pods use Ports; the bare-metal node at `45.76.77.97` continues to use Cloud Hypervisor)

### What's given up

- **MicroVM isolation.** The supervised process shares the host kernel, filesystem, and process namespace. No cgroups isolation beyond what the container runtime provides.
- **Snapshot/restore.** No BTRFS subvolume snapshots, no reflinks. State persistence is whatever the workload itself implements.
- **virtio-fs / vsock semantics.** Communication with the workload is via stdio (OTP Port) or whatever protocol the workload speaks on its listening port.
- **Per-VM TAP networking.** The workload is reachable on the container's network namespace, not in `10.200.0.0/16`.

### When to choose this profile

- The host is a containerized rental (e.g. RunPod, Vast.ai, Modal).
- A single workload (e.g. a GPU inference server) needs to be supervised, not isolated from other workloads, and the operator accepts the container as the isolation boundary.
- You want a uniform API across a fleet that mixes bare-metal hosts (full profile) and rented containers (OTP-only).

### When *not* to choose this profile

- Multi-tenant workloads where guests must be isolated from each other.
- Snapshot/clone is a load-bearing feature for the use case.
- A microVM is the unit of distribution (e.g. for a remote-shell product).

---

## 8. Verified-Incompatible Environments

Documented here so they don't get tried twice.

| Environment | Reason |
|---|---|
| **RunPod GPU pods (containerized)** | No `/dev/kvm` in tenant container; no IOMMU access; cannot rebind GPU to vfio-pci. OTP-only profile works. |
| **Vast.ai containers** | Same as RunPod. OTP-only profile works subject to provider's container capabilities. |
| **Modal serverless** | No persistent host, no KVM. OTP-only profile only viable if Modal's container exposes long-lived TCP/HTTP — generally yes, but cold-start semantics differ. |
| **Google Cloud Run, AWS Fargate, Azure Container Instances** | No nested-virt, no KVM. OTP-only profile possible but pointless — these platforms already provide their own supervision. |
| **macOS** | No KVM. (Apple Hypervisor.framework is a different API; Cloud Hypervisor does not target it.) |
| **WSL2 (Windows Subsystem for Linux)** | KVM is *technically* available in WSL2's kernel for nested virt, but virtio-fs + BTRFS on WSL2 has known stability issues. Not recommended. |

---

## 9. Pre-Flight Checklist for a New Host

Run before attempting `just deploy` against a fresh box. Each line below should succeed cleanly.

```bash
# 1. CPU virt extensions
grep -E 'vmx|svm' /proc/cpuinfo | head -1

# 2. KVM available and group membership
ls -l /dev/kvm
id | grep -o 'kvm'                    # the deploy user should be in the kvm group

# 3. BTRFS at the data root
mkdir -p /var/lib/mjolnir
findmnt -no FSTYPE /var/lib/mjolnir   # btrfs (mount it explicitly if not)

# 4. Reflink works
cp --reflink=always /etc/hostname /tmp/.mjolnir-reflink-test && rm /tmp/.mjolnir-reflink-test

# 5. Networking primitives
sysctl net.ipv4.ip_forward            # 1
modprobe tun && modprobe vhost_vsock
lsmod | grep -E 'tun|vhost_vsock'

# 6. Cloud Hypervisor present
cloud-hypervisor --version            # v50.0 or compatible

# 7. (GPU hosts only) IOMMU + VFIO
dmesg | grep -E 'IOMMU|DMAR' | head   # IOMMU enabled at boot
ls /sys/kernel/iommu_groups/          # non-empty
modprobe vfio-pci && lsmod | grep vfio
```

If any of these fail on a host that's intended for the **full profile**, fix before deploying. If GPU passthrough is needed, §5 is the gating section — `dmesg | grep IOMMU` is the single most diagnostic line.

For an **OTP-only profile** deployment, only §6 (host OS) and a working network egress are required.
