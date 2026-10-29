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

# The ch-6.12.8 driver feeds the counter to random.c and stops. Userspace
# has no /dev/vmgenid on this tree. Export the live 16 bytes as 32 hex
# digits at /sys/firmware/vmgenid/generation_id. Idempotent.
python3 - <<'PY'
from pathlib import Path
path = Path("drivers/virt/vmgenid.c")
text = path.read_text()
if "mjolnir_vmgenid_state" in text:
    raise SystemExit(0)
old = """#include <linux/random.h>
"""
new = """#include <linux/kobject.h>
#include <linux/random.h>
#include <linux/sysfs.h>
"""
if old not in text:
    raise SystemExit("vmgenid.c includes changed; refusing to patch")
text = text.replace(old, new, 1)
old = """struct vmgenid_state {
	u8 *next_id;
	u8 this_id[VMGENID_SIZE];
};
"""
new = """struct vmgenid_state {
	u8 *next_id;
	u8 this_id[VMGENID_SIZE];
};

static struct vmgenid_state *mjolnir_vmgenid_state;
static struct kobject *mjolnir_vmgenid_kobj;

static ssize_t generation_id_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	struct vmgenid_state *state = READ_ONCE(mjolnir_vmgenid_state);
	(void)kobj;
	(void)attr;
	u8 id[VMGENID_SIZE];
	int i;

	if (!state || !state->next_id)
		return -ENODEV;
	memcpy(id, state->next_id, VMGENID_SIZE);
	for (i = 0; i < VMGENID_SIZE; i++)
		sprintf(buf + (i * 2), "%02x", id[i]);
	buf[VMGENID_SIZE * 2] = '\\n';
	return VMGENID_SIZE * 2 + 1;
}
static struct kobj_attribute mjolnir_generation_id_attr = __ATTR_RO(generation_id);
"""
if old not in text:
    raise SystemExit("vmgenid_state struct changed; refusing to patch")
text = text.replace(old, new, 1)
old = """	memcpy(state->this_id, state->next_id, sizeof(state->this_id));
	add_device_randomness(state->this_id, sizeof(state->this_id));
"""
new = """	memcpy(state->this_id, state->next_id, sizeof(state->this_id));
	WRITE_ONCE(mjolnir_vmgenid_state, state);
	add_device_randomness(state->this_id, sizeof(state->this_id));
"""
if old not in text:
    raise SystemExit("setup_vmgenid_state changed; refusing to patch")
text = text.replace(old, new, 1)
old = """	if (ret < 0)
		devm_kfree(dev, state);
	return ret;
}
"""
new = """	if (ret < 0) {
		devm_kfree(dev, state);
		return ret;
	}
	if (!mjolnir_vmgenid_kobj) {
		mjolnir_vmgenid_kobj = kobject_create_and_add("vmgenid", firmware_kobj);
		if (mjolnir_vmgenid_kobj)
			sysfs_create_file(mjolnir_vmgenid_kobj, &mjolnir_generation_id_attr.attr);
	}
	return 0;
}
"""
if old not in text:
    raise SystemExit("vmgenid_add tail changed; refusing to patch")
text = text.replace(old, new, 1)
path.write_text(text)
PY

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

# EFI stub is unused in PVH boot — disable it to avoid GCC 15 C23 bool/false keyword conflicts
./scripts/config --disable CONFIG_EFI_STUB

# GCC 15 defaults to C23, which makes bool/false/true keywords, breaking the compressed boot stub.
# The arch/x86/boot/compressed/ subdir sets its own KBUILD_CFLAGS without -std=gnu11,
# so it doesn't inherit the kernel's C standard. Patch it explicitly.
if ! grep -q -- '-std=gnu11' arch/x86/boot/compressed/Makefile; then
    echo "Patching compressed boot Makefile for GCC 15 C23 compatibility..."
    sed -i '/^KBUILD_CFLAGS := -m\$(BITS)/a KBUILD_CFLAGS += -std=gnu11' arch/x86/boot/compressed/Makefile
fi

# dm-crypt for LUKS encrypted secrets volumes
./scripts/config --enable CONFIG_BLK_DEV_DM
./scripts/config --enable CONFIG_DM_CRYPT
./scripts/config --enable CONFIG_CRYPTO_XTS
./scripts/config --enable CONFIG_CRYPTO_AES

# VM Generation ID. The symbol lives under the VIRT_DRIVERS menu; enabling
# only CONFIG_VMGENID leaves it unset once `make` syncs the config.
# Built-in: PVH has no initramfs to load a module, and the driver has to be
# in the image a snapshot captures.
./scripts/config --enable CONFIG_VIRT_DRIVERS
./scripts/config --enable CONFIG_VMGENID
# So the host can read the captured kernel's capability back out of the
# boot file (IKCFG_ST … IKCFG_ED) without a side record.
./scripts/config --enable CONFIG_IKCONFIG
./scripts/config --enable CONFIG_IKCONFIG_PROC

# Resolve new symbols non-interactively. `make bzImage` otherwise runs
# oldconfig, reads EOF, and can drop VMGENID when its menu was off.
make olddefconfig

# Verification: ensure critical configs are =y (built-in, not module)
echo "Verifying kernel configuration..."
VERIFY_FAILED=0
for opt in CONFIG_VIRTIO_FS CONFIG_FUSE_FS CONFIG_PVH CONFIG_DM_CRYPT CONFIG_BLK_DEV_DM CONFIG_VIRT_DRIVERS CONFIG_VMGENID CONFIG_IKCONFIG CONFIG_IKCONFIG_PROC; do
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
    if ! scripts/extract-ikconfig "$KERNEL_OUTPUT" | grep -q '^CONFIG_VMGENID=y$'; then
        echo "FATAL: $KERNEL_OUTPUT has no embedded CONFIG_VMGENID=y"
        exit 1
    fi
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
