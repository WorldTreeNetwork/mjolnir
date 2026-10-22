# Run a node (mini-hosters)

Plug in a box. It becomes an Iroh-addressed compute node. Other
people's `mj` clients spawn VMs on it. Local services are reachable
wherever Lightning Mesh backhaul radios reach. That is the whole
product for an operator.

The software on the box is **AGPL-3.0-or-later**. You do not buy a
license from World Tree LLC to run it. The LLC sells mesh *hardware*
(radios / nodes). The Foundation publishes the code. Unmodified, this
repository is the source offer AGPL asks for.

Consumer path (laptop, MIT CLI): [Getting Started](getting-started.md).
This page is the operator path.

---

## Ship-today SKU: x86_64 mini-PC

| | Minimum | Comfortable |
|---|---|---|
| CPU | x86_64 with VT-x or AMD-V, `/dev/kvm` | N100/N305 or better |
| RAM | 8 GB (tight) | 16 GB+ |
| Disk | 64 GB BTRFS, SSD | 256 GB+ NVMe |
| OS | Ubuntu 22.04+ / Debian 12 | Ubuntu 24.04 |

Full rationale: [hardware-requirements.md](../hardware-requirements.md).
KVM and BTRFS are not optional for microVMs.

```bash
git clone https://github.com/Identikey/mjolnir.git   # WorldTreeNetwork after transfer
cd mjolnir
sudo BTRFS_DEVICE=/dev/nvme0n1pN ./scripts/bootstrap-host-ubuntu.sh
# or: sudo USE_LOOPBACK=1 ./scripts/bootstrap-host-ubuntu.sh
```

After bootstrap the orchestrator is a systemd service. `mj doctor`
from any machine with the MIT CLI confirms the API + host.

Put the box on the mesh (Lightning Mesh radio on the same island, or
plain Ethernet). VMs get an Iroh endpoint at boot. Clients connect
with `mj connect` (PTY; `--session NAME` attaches tmux) from anywhere
Iroh can NAT-traverse, and from the island by whatever name the
radios already know.

---

## Raspberry Pi — goal, not today

Pi 5 has KVM on 64-bit Raspberry Pi OS. Cloud Hypervisor has ARM64
upstream. **This repo does not ship that path yet:** the guest agent
and rootfs are `x86_64-unknown-linux-musl` only. BTRFS on an SD card
is a bad idea; USB/NVMe storage would be required even after ARM
lands.

If you want a $50–$80 node *now*, that is a Lightning Mesh radio
(OpenWrt, 802.11s backhaul), not a Mjolnir hypervisor. Compute waits
for a mini-PC, or for the ARM port.

---

## What the box can host

Anything that fits in a Linux microVM:

- A shell (`mj spawn` / `mj connect`) — real PTY, tmux-multiplexed.
- A deployed app (`mj deploy`) with secrets mapped to env vars at
  spawn. Secrets never enter the snapshot.
  [Deploying a Web App](deploying-an-app.md),
  [secrets architecture](../secrets-architecture.md).
- GPU workloads, **if this host** has IOMMU and an isolatable GPU.
  Most mini-PCs do not. A discrete-GPU box on the mesh is enough:
  clients do not need the GPU locally; they reach the VM over Iroh.
  [hardware-requirements.md §5](../hardware-requirements.md).

Any computer on the island can be a host. The radios carry the
services; Iroh carries them off-island.

---

## Related

- [README — run your own server](../../README.md#run-your-own-server)
- [Lightning Mesh](https://github.com/WorldTreeNetwork/lightning-mesh)
  — the radio / Iroh base layer
- [Licensing](../philosophy/licensing-and-components.md)
