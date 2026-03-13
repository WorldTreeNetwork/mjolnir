#!/bin/bash
set -euo pipefail

# Build a Linux kernel for Cloud Hypervisor with virtio-fs support.
#
# This produces a PVH-capable kernel with virtio-fs, vsock, and networking
# support built-in (=y, not =m) since PVH boot has no initramfs.
#
# Usage: sudo ./scripts/build-kernel.sh
# Output: /var/lib/mjolnir/vmlinux-ch

MJOLNIR_ROOT="${MJOLNIR_ROOT:-/var/lib/mjolnir}"
KERNEL_OUTPUT="${1:-$MJOLNIR_ROOT/vmlinux-ch}"
CH_LINUX_DIR="/tmp/linux-cloud-hypervisor"
CH_KERNEL_BRANCH="ch-6.12.8"

echo "=== Building Cloud Hypervisor Kernel ==="
echo "Output: $KERNEL_OUTPUT"
echo "Branch: $CH_KERNEL_BRANCH"
echo ""

# Must be root (for installing build deps)
if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root"
    exit 1
fi

# Install kernel build dependencies
echo "Installing build dependencies..."
apt-get install -y --no-install-recommends \
    flex bison libelf-dev bc gcc make git 2>/dev/null || true

# Clone Cloud Hypervisor's linux fork
if [[ -d "$CH_LINUX_DIR" ]]; then
    echo "Linux source already cloned at $CH_LINUX_DIR"
else
    echo "Cloning Cloud Hypervisor linux branch ($CH_KERNEL_BRANCH)..."
    git clone --depth 1 "https://github.com/cloud-hypervisor/linux.git" \
        -b "$CH_KERNEL_BRANCH" "$CH_LINUX_DIR"
fi

cd "$CH_LINUX_DIR"

# Configure with CH defaults
echo "Configuring with ch_defconfig..."
make ch_defconfig

# Enable required configs via scripts/config
# These MUST be =y (built-in), NOT =m (module), because PVH boot
# has no initramfs to load modules before root mount.
echo "Enabling virtio-fs and related configs..."
./scripts/config --enable CONFIG_PVH
./scripts/config --enable CONFIG_VIRTIO_FS
./scripts/config --enable CONFIG_FUSE_FS
./scripts/config --enable CONFIG_VIRTIO_VSOCK
./scripts/config --enable CONFIG_VIRTIO_NET
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_NET_9P

# dm-crypt for LUKS encrypted secrets volumes
./scripts/config --enable CONFIG_BLK_DEV_DM
./scripts/config --enable CONFIG_DM_CRYPT
./scripts/config --enable CONFIG_CRYPTO_XTS
./scripts/config --enable CONFIG_CRYPTO_AES

# Verification: ensure critical configs are =y (built-in, not module)
echo "Verifying kernel configuration..."
VERIFY_FAILED=0
for opt in CONFIG_VIRTIO_FS CONFIG_FUSE_FS CONFIG_PVH CONFIG_DM_CRYPT CONFIG_BLK_DEV_DM; do
    val=$(grep "^${opt}=" .config | cut -d= -f2)
    if [ "$val" != "y" ]; then
        echo "FATAL: $opt is '$val', must be 'y' (built-in, not module)"
        VERIFY_FAILED=1
    else
        echo "  OK: $opt=y"
    fi
done

if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo ""
    echo "Kernel configuration verification failed!"
    exit 1
fi

echo ""
echo "All critical configs verified as built-in (=y)"
echo ""

# Build
echo "Building kernel (this takes a few minutes)..."
KCFLAGS="-Wa,-mx86-used-note=no" make -j"$(nproc)" bzImage

# Install
VMLINUX_BIN="arch/x86/boot/compressed/vmlinux.bin"
if [[ -f "$VMLINUX_BIN" ]]; then
    mkdir -p "$(dirname "$KERNEL_OUTPUT")"
    cp "$VMLINUX_BIN" "$KERNEL_OUTPUT"
    chmod 644 "$KERNEL_OUTPUT"
    echo ""
    echo "=== Kernel Built ==="
    echo "File: $KERNEL_OUTPUT"
    echo "Size: $(du -h "$KERNEL_OUTPUT" | cut -f1)"
    echo ""
    echo "Verify with: grep CONFIG_VIRTIO_FS=y $CH_LINUX_DIR/.config"
else
    echo "FATAL: Kernel build failed — $VMLINUX_BIN not found"
    exit 1
fi

# Clean up source to save disk
if [[ "${KEEP_SOURCE:-0}" != "1" ]]; then
    echo "Cleaning up source (set KEEP_SOURCE=1 to keep)..."
    rm -rf "$CH_LINUX_DIR"
fi
