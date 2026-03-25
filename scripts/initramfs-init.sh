#!/bin/sh
# Mjolnir initramfs init (Phase A: flat rootfs)
# This file is copied to /init (mode 0755) inside the cpio archive by build-initramfs.sh.

# Mount kernel filesystems
# NOTE: CONFIG_DEVTMPFS_MOUNT=y auto-mounts devtmpfs for the real rootfs,
# but NOT for initramfs. Without this, /dev/vsock does not exist and the
# boot agent cannot open vsock.
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo "[boot] Mjolnir Boot v1" > /dev/console
echo "[mount] devtmpfs mounted" > /dev/console

# Start boot agent (vsock ping + PTY) in background.
# Must start BEFORE virtiofs mount so the host can detect initramfs readiness
# even if the mount hangs, and so the emergency shell is reachable via PTY.
/bin/mjolnir-boot-agent &

echo "[agent] Boot agent starting..." > /dev/console

# Mount the virtiofs rootfs (same flat layout as legacy boot)
echo "[mount] Mounting rootfs (virtiofs:myfs)..." > /dev/console
mkdir -p /mnt/root
mount -t virtiofs myfs /mnt/root

if [ $? -ne 0 ]; then
    echo "[!] FATAL: virtiofs mount failed" > /dev/console
    # Emergency shell accessible via vsock PTY from boot agent
    exec /bin/sh
fi

echo "[mount] Rootfs mounted" > /dev/console

# Clean up kernel mounts before switch_root.
# /dev is NOT unmounted — switch_root needs device nodes,
# and systemd will re-mount/manage devtmpfs after pivot.
umount /proc
umount /sys

# switch_root: atomically moves the mount, deletes the initramfs tmpfs,
# and execs the real init. This kills all initramfs processes (including
# the boot agent) — expected, boot agent holds no persistent state.
echo "[switch] Executing switch_root..." > /dev/console
exec switch_root /mnt/root /sbin/init
