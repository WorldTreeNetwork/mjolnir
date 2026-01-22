#!/bin/bash
set -euo pipefail

# Mjolnir Host Setup Script
# Run as root on a fresh Debian 12 or Ubuntu 22.04 system

MJOLNIR_ROOT="/var/lib/mjolnir"
BTRFS_DEVICE="${BTRFS_DEVICE:-}"
FC_VERSION="1.5.0"

echo "=== Mjolnir Host Setup ==="

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root"
        exit 1
    fi

    # Check KVM support
    if [[ ! -e /dev/kvm ]]; then
        echo "Error: KVM not available. Enable virtualization in BIOS."
        exit 1
    fi

    # Check for BTRFS device if not set
    if [[ -z "$BTRFS_DEVICE" ]]; then
        echo "BTRFS_DEVICE not set. Available block devices:"
        lsblk
        read -rp "Enter device for BTRFS (e.g., /dev/sdb): " BTRFS_DEVICE
    fi

    if [[ ! -b "$BTRFS_DEVICE" ]]; then
        echo "Error: $BTRFS_DEVICE is not a block device"
        exit 1
    fi

    echo "Prerequisites OK"
}

# Install system packages
install_packages() {
    echo "Installing packages..."

    apt-get update
    apt-get install -y \
        btrfs-progs \
        curl \
        wget \
        git \
        build-essential \
        erlang \
        elixir \
        jq

    echo "Packages installed"
}

# Install Firecracker
install_firecracker() {
    echo "Installing Firecracker v${FC_VERSION}..."

    local arch
    arch=$(uname -m)

    local url="https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-${arch}.tgz"

    curl -L "$url" | tar xz -C /tmp

    mv "/tmp/release-v${FC_VERSION}-${arch}/firecracker-v${FC_VERSION}-${arch}" /usr/local/bin/firecracker
    mv "/tmp/release-v${FC_VERSION}-${arch}/jailer-v${FC_VERSION}-${arch}" /usr/local/bin/jailer

    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer

    rm -rf "/tmp/release-v${FC_VERSION}-${arch}"

    echo "Firecracker installed: $(firecracker --version)"
}

# Setup BTRFS filesystem
setup_btrfs() {
    echo "Setting up BTRFS on ${BTRFS_DEVICE}..."

    # Create BTRFS filesystem
    mkfs.btrfs -f -L mjolnir "$BTRFS_DEVICE"

    # Create mount point
    mkdir -p "$MJOLNIR_ROOT/btrfs"

    # Mount with optimal options
    mount -o compress=zstd:3,noatime,ssd,discard=async "$BTRFS_DEVICE" "$MJOLNIR_ROOT/btrfs"

    # Add to fstab
    local uuid
    uuid=$(blkid -s UUID -o value "$BTRFS_DEVICE")
    echo "UUID=$uuid $MJOLNIR_ROOT/btrfs btrfs compress=zstd:3,noatime,ssd,discard=async 0 0" >> /etc/fstab

    # Create subvolume structure
    btrfs subvolume create "$MJOLNIR_ROOT/btrfs/@base"
    btrfs subvolume create "$MJOLNIR_ROOT/btrfs/@vms"
    btrfs subvolume create "$MJOLNIR_ROOT/btrfs/@snapshots"
    btrfs subvolume create "$MJOLNIR_ROOT/btrfs/@workspaces"

    # Enable quotas
    btrfs quota enable "$MJOLNIR_ROOT/btrfs"

    echo "BTRFS setup complete"
}

# Build Firecracker kernel from source or download pre-built
download_kernel() {
    echo "Setting up Firecracker kernel..."

    mkdir -p "$MJOLNIR_ROOT"

    # Option 1: Download pre-built kernel from Firecracker releases
    # This is a minimal kernel config optimized for Firecracker
    local kernel_version="5.10.217"
    local kernel_url="https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/vmlinux-${kernel_version}"

    if curl -fsSL "$kernel_url" -o "$MJOLNIR_ROOT/vmlinux" 2>/dev/null; then
        echo "Downloaded pre-built kernel ${kernel_version}"
    else
        # Fallback: build from source (takes longer but no external dependency)
        echo "Pre-built kernel not available, will need to build from source"
        echo "See: https://github.com/firecracker-microvm/firecracker/blob/main/docs/rootfs-and-kernel-setup.md"
        exit 1
    fi

    echo "Kernel installed to $MJOLNIR_ROOT/vmlinux"
}

# Build custom Debian 12 rootfs with guest agent
build_base_rootfs() {
    echo "Building Debian 12 base rootfs..."

    local rootfs_path="$MJOLNIR_ROOT/btrfs/@base/debian-12"
    local tmp_rootfs="/tmp/debian-12-rootfs"
    local tmp_ext4="/tmp/debian-12.ext4"

    # Check for guest agent binary
    local agent_bin=""
    if [[ -f "/opt/mjolnir/native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent" ]]; then
        agent_bin="/opt/mjolnir/native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    elif [[ -f "./native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent" ]]; then
        agent_bin="./native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    fi

    if [[ -z "$agent_bin" ]]; then
        echo "WARNING: Guest agent not found. Build it first with:"
        echo "  cd native/mjolnir_guest_agent"
        echo "  rustup target add x86_64-unknown-linux-musl"
        echo "  cargo build --release --target x86_64-unknown-linux-musl"
        echo ""
        echo "Continuing without guest agent (vsock commands will not work)..."
    fi

    # Create sparse ext4 image (1GB, but sparse so only uses actual space)
    echo "Creating ext4 image..."
    dd if=/dev/zero of="$tmp_ext4" bs=1M count=0 seek=1024
    mkfs.ext4 -q "$tmp_ext4"

    # Mount it
    mkdir -p "$tmp_rootfs"
    mount -o loop "$tmp_ext4" "$tmp_rootfs"

    # Bootstrap minimal Debian 12
    echo "Bootstrapping Debian 12 (this takes a few minutes)..."
    debootstrap --variant=minbase \
        --include=systemd,systemd-sysv,dbus,procps,curl,ca-certificates \
        bookworm "$tmp_rootfs" http://deb.debian.org/debian

    # Configure hostname
    echo "mjolnir-vm" > "$tmp_rootfs/etc/hostname"

    # Configure hosts
    cat > "$tmp_rootfs/etc/hosts" << 'HOSTS'
127.0.0.1 localhost mjolnir-vm
::1 localhost
HOSTS

    # Configure fstab (minimal)
    cat > "$tmp_rootfs/etc/fstab" << 'FSTAB'
/dev/vda / ext4 defaults 0 1
FSTAB

    # Enable serial console for debugging
    mkdir -p "$tmp_rootfs/etc/systemd/system/serial-getty@ttyS0.service.d"
    cat > "$tmp_rootfs/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'SERIAL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
SERIAL

    chroot "$tmp_rootfs" systemctl enable serial-getty@ttyS0.service

    # Set root password for debugging (can SSH in if networking enabled)
    echo "root:mjolnir" | chroot "$tmp_rootfs" chpasswd

    # Install guest agent if available
    if [[ -n "$agent_bin" ]]; then
        echo "Installing guest agent..."
        cp "$agent_bin" "$tmp_rootfs/usr/local/bin/mjolnir-agent"
        chmod +x "$tmp_rootfs/usr/local/bin/mjolnir-agent"

        # Create systemd service
        cat > "$tmp_rootfs/etc/systemd/system/mjolnir-agent.service" << 'AGENT'
[Unit]
Description=Mjolnir Guest Agent
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mjolnir-agent
Restart=always
RestartSec=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
AGENT

        chroot "$tmp_rootfs" systemctl enable mjolnir-agent.service
        echo "Guest agent installed and enabled"
    fi

    # Clean up apt cache to reduce size
    chroot "$tmp_rootfs" apt-get clean
    rm -rf "$tmp_rootfs/var/lib/apt/lists/"*

    # Unmount
    umount "$tmp_rootfs"
    rmdir "$tmp_rootfs"

    # Copy to BTRFS as subvolume
    echo "Copying to BTRFS..."
    mkdir -p /tmp/rootfs-mount
    mount -o loop "$tmp_ext4" /tmp/rootfs-mount

    # Create the base subvolume by copying contents
    btrfs subvolume create "$rootfs_path" 2>/dev/null || mkdir -p "$rootfs_path"
    cp -a /tmp/rootfs-mount/* "$rootfs_path/"

    umount /tmp/rootfs-mount
    rmdir /tmp/rootfs-mount
    rm "$tmp_ext4"

    echo "Debian 12 rootfs installed to $rootfs_path"
    du -sh "$rootfs_path"
}

# Create socket directory
setup_sockets() {
    echo "Setting up socket directory..."

    mkdir -p /tmp/mjolnir
    chmod 755 /tmp/mjolnir

    echo "Socket directory ready"
}

# Print summary
print_summary() {
    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Mjolnir root:     $MJOLNIR_ROOT"
    echo "BTRFS partition:  $BTRFS_DEVICE"
    echo "Kernel:           $MJOLNIR_ROOT/vmlinux"
    echo "Base images:      $MJOLNIR_ROOT/btrfs/@base/"
    echo "Socket dir:       /tmp/mjolnir"
    echo ""
    echo "Next steps:"
    echo "  1. cd /path/to/mjolnir"
    echo "  2. mix deps.get"
    echo "  3. iex -S mix"
    echo "  4. Mjolnir.VM.spawn()"
    echo ""
}

# Main
main() {
    check_prerequisites
    install_packages
    install_firecracker
    setup_btrfs
    download_kernel
    build_base_rootfs
    setup_sockets
    print_summary
}

main "$@"
