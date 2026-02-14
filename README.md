# Mjolnir Orchestrator

Distributed computational fabric for spawning checkpointable Linux shells in Firecracker microVMs with NAT-traversing remote access via [Iroh](https://iroh.computer).

## Requirements

### Hardware

| Requirement | Minimum | Recommended | How to Check |
|-------------|---------|-------------|--------------|
| CPU | x86_64 with VT-x/AMD-V | Same | `grep -E "(vmx|svm)" /proc/cpuinfo` |
| KVM | Enabled in BIOS | Same | `ls -la /dev/kvm` |
| Memory | 4 GB | 8+ GB | `free -h` |
| Disk | 20 GB free | 50+ GB free | `df -h /` |

### Software

| Requirement | Version | Notes |
|-------------|---------|-------|
| OS | Ubuntu 22.04+, Debian 12+ | Other distros may work but untested |
| Kernel | 5.10+ | `uname -r` |
| Firecracker | 1.5+ | Installed by bootstrap script |
| Erlang | 26+ | Installed by bootstrap script via mise |
| Elixir | 1.15+ | Installed by bootstrap script via mise |
| Rust | stable | Installed by bootstrap script (for guest agent) |

### Pre-flight Checklist

Run these commands before setup to verify your system is ready:

```bash
# 1. Check architecture (must be x86_64)
uname -m

# 2. Check for Intel VT-x or AMD-V (should output "vmx" or "svm")
grep -oE "(vmx|svm)" /proc/cpuinfo | head -1

# 3. Check if KVM is available
ls -la /dev/kvm
# If missing, try: sudo modprobe kvm && sudo modprobe kvm_intel  # (or kvm_amd)

# 4. Check if you're in the kvm group (needed for non-root access)
groups | grep -q kvm && echo "OK: in kvm group" || echo "WARN: not in kvm group"
# To fix: sudo usermod -aG kvm $USER && newgrp kvm

# 5. Check available disk space (need 20GB+ free)
df -h /var/lib

# 6. Check if running in a VM (nested virt required if so)
grep -q "^flags.*hypervisor" /proc/cpuinfo && echo "Running in VM - needs nested virt" || echo "Bare metal OK"
```

## Quick Start

### Option A: Dev Bootstrap (Recommended for Contributors)

Sets up everything while keeping code in your workspace for live editing:

```bash
# Clone the repo
git clone https://github.com/IdentiKey/mjolnir.git
cd mjolnir

# Run dev bootstrap (loopback if no spare disk)
sudo DEV_MODE=1 USE_LOOPBACK=1 ./scripts/bootstrap-host.sh
```

### Option B: Production Bootstrap

Deploys to `/opt/mjolnir` for production use:

```bash
# With loopback storage
sudo USE_LOOPBACK=1 ./scripts/bootstrap-host.sh

# Or with a dedicated device
sudo BTRFS_DEVICE=/dev/sdb ./scripts/bootstrap-host.sh
```

### Option C: Manual Setup (Already Have Deps Installed)

If you already have Erlang 26+, Elixir 1.15+, Rust, and Firecracker:

```bash
# Install mise and project tool versions
curl https://mise.run | sh
eval "$(mise activate bash)"
mise trust && mise install

# Build the guest agent
./scripts/build-guest-agent.sh

# Get Elixir deps
mix deps.get

# You still need BTRFS storage, kernel, and rootfs from bootstrap
# or set up manually per docs/roadmap.md
```

### Running the Orchestrator

```bash
# Start with sudo (required for TAP interfaces and Firecracker)
just iex-root

# Or manually:
sudo bash -c "eval \"\$(mise activate bash)\" && iex -S mix"
```

Dev mode uses isolated paths (`@vms-dev`, `/tmp/mjolnir-dev`) so you won't clobber prod.

#### Via Control Server (Recommended)

```bash
# In another terminal while orchestrator is running:
just vm-spawn                    # Returns JSON with vm_id, iroh_ticket, etc.
just vm-exec <vm_id> "uname -a"  # Execute command in VM
just vm-list                     # List running VMs
just vm-stop <vm_id>             # Stop VM
```

#### Via IEx (Interactive)

```elixir
# Spawn a VM
{:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-24.04", memory_mb: 1024})

# Check Iroh shell status
vm.shell_ready  # true if connected to relay
vm.iroh_ticket  # Connection ticket for remote access

# Execute a command
{:ok, output} = Mjolnir.VM.exec(vm.id, "uname -a")

# Stop the VM
:ok = Mjolnir.VM.stop(vm.id)

# Hot reload after code changes (no restart needed)
recompile()
```

## Control Server

The orchestrator exposes a TCP control server on `localhost:9999` for managing VMs via JSON commands.
This enables CLI tools, scripts, and AI agents to interact with Mjolnir without needing Elixir.

```bash
# Start the orchestrator (requires sudo for TAP/Firecracker)
just iex-root

# In another terminal, use the control commands:
just vm-spawn                           # Spawn a VM
just vm-list                            # List running VMs
just vm-exec <vm_id> "uname -a"         # Execute command
just vm-stop <vm_id>                    # Stop a VM

# Or use netcat directly:
echo '{"cmd":"spawn"}' | nc -q1 localhost 9999 | jq .
echo '{"cmd":"exec","vm_id":"...","command":"ls"}' | nc -q1 localhost 9999
```

See `Mjolnir.ControlServer` module docs for the full command reference.

## Current Limitations

- **No interactive shell client** — VMs have Iroh endpoints ready, but the CLI client isn't built yet.
- **Single node** — VMs run on local host only. Distributed scheduling is a future milestone.

## Bootstrap Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEV_MODE` | `0` | Set to `1` for dev setup (workspace-based, no /opt deploy) |
| `BTRFS_DEVICE` | (prompts) | Block device for BTRFS, e.g. `/dev/sdb` |
| `USE_LOOPBACK` | `0` | Set to `1` to create a loopback file instead of using a device |
| `BTRFS_LOOPBACK_SIZE_GB` | `50` | Size of loopback file when using `USE_LOOPBACK=1` |
| `SKIP_BTRFS` | `0` | Set to `1` to skip BTRFS setup |
| `SKIP_ROOTFS` | `0` | Set to `1` to skip rootfs build |
| `MJOLNIR_REPO` | (current dir) | Git repo URL if not running from repo |
| `MJOLNIR_BRANCH` | `main` | Git branch to checkout |

## Troubleshooting

### `/dev/kvm` not found

```bash
# Load KVM modules
sudo modprobe kvm
sudo modprobe kvm_intel  # or kvm_amd for AMD CPUs

# Make persistent
echo "kvm" | sudo tee /etc/modules-load.d/kvm.conf
echo "kvm_intel" | sudo tee -a /etc/modules-load.d/kvm.conf
```

### Permission denied on `/dev/kvm`

```bash
# Add yourself to the kvm group
sudo usermod -aG kvm $USER

# Apply without logout (for current shell)
newgrp kvm
```

### Firecracker fails to start VM

Check if running inside a VM without nested virtualization:
```bash
# If this shows hypervisor flag, you're in a VM
grep "hypervisor" /proc/cpuinfo

# For cloud VMs, enable nested virt in your provider's console
# For local VMs (VirtualBox, VMware), enable VT-x/AMD-V passthrough
```

## Documentation

- [Roadmap](docs/roadmap.md)
- [MicroVM Fabric Spec](docs/microvm-fabric.md)
- [Computational Fabric Theory](docs/computational-fabric.md)

## License

MIT
