#!/bin/bash
set -euo pipefail

# Build a CI-optimized Ubuntu 24.04 BTRFS subvolume rootfs for Mjolnir VMs.
#
# This image is designed for running CI jobs (Forgejo Actions, etc.) inside
# Mjolnir microVMs. It includes build tools, VCS, runtimes, and a non-root
# "runner" user, plus a systemd service for virtio-fs workspace mounts.
# Syslog forwarding is handled natively by the Mjolnir guest agent.
#
# Usage: sudo ./scripts/build-ci-image.sh [output-path]
# Example: sudo ./scripts/build-ci-image.sh /var/lib/mjolnir/btrfs/@base/ci-ubuntu-24.04
#
# The script is idempotent: if the subvolume already exists it is deleted and
# recreated from scratch.
#
# Prerequisites (on the server):
#   apt-get install -y debootstrap btrfs-progs

OUTPUT="${1:-/var/lib/mjolnir/btrfs/@base/ci-ubuntu-24.04}"

# The directory this script lives in — used to locate the ci-image/ assets.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ASSETS="$SCRIPT_DIR/ci-image"

# shellcheck source=lib/guest-agent.sh
source "$SCRIPT_DIR/lib/guest-agent.sh"

echo "=== Building CI Ubuntu 24.04 Rootfs (BTRFS subvolume) ==="
echo "Output:     $OUTPUT"
echo "Assets dir: $CI_ASSETS"
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (need debootstrap, btrfs, chroot)"
    exit 1
fi

if ! command -v debootstrap &>/dev/null; then
    echo "Error: debootstrap not found."
    echo "  apt-get install -y debootstrap"
    exit 1
fi

if ! command -v btrfs &>/dev/null; then
    echo "Error: btrfs-progs not found."
    echo "  apt-get install -y btrfs-progs"
    exit 1
fi

# ── Subvolume setup ──────────────────────────────────────────────────────────

mkdir -p "$(dirname "$OUTPUT")"

if [[ -d "$OUTPUT" ]]; then
    echo "Removing existing subvolume: $OUTPUT"
    btrfs subvolume delete "$OUTPUT" 2>/dev/null || rm -rf "$OUTPUT"
fi

echo "Creating BTRFS subvolume: $OUTPUT"
btrfs subvolume create "$OUTPUT"

# The subvolume IS the rootfs directory — no loop-mount needed.
R="$OUTPUT"

cleanup() {
    # Unmount any proc/sys/dev that chroot may have left behind.
    for mnt in proc sys dev/pts dev; do
        mountpoint -q "$R/$mnt" 2>/dev/null && umount -lf "$R/$mnt" || true
    done
}
trap cleanup EXIT

# ── Bootstrap ────────────────────────────────────────────────────────────────

echo ""
echo "--- Bootstrapping Ubuntu 24.04 Noble (minbase) ---"
debootstrap --variant=minbase \
    --include=systemd,systemd-sysv,dbus,procps,iproute2,ca-certificates,gpg \
    noble "$R" http://archive.ubuntu.com/ubuntu

# ── Hostname / hosts / fstab ─────────────────────────────────────────────────

echo "ci-runner" > "$R/etc/hostname"

cat > "$R/etc/hosts" << 'EOF'
127.0.0.1 localhost ci-runner
::1       localhost
EOF

# Root fs is a virtio-fs share — tag "myfs" matches Cloud Hypervisor fs_config.
cat > "$R/etc/fstab" << 'EOF'
myfs / virtiofs rw 0 0
EOF

# ── APT repositories ──────────────────────────────────────────────────────────

echo ""
echo "--- Configuring apt sources (universe + updates + security) ---"
cat > "$R/etc/apt/sources.list.d/ubuntu.sources" << 'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq"

# ── CI packages ──────────────────────────────────────────────────────────────
#
# Installed in a single apt-get call to keep the layer tight.  Groups:
#   Build tools    — compilers, cmake, autotools, pkg-config
#   VCS            — git, git-lfs
#   Network        — curl, wget, ca-certificates
#   Runtimes       — nodejs, npm, python3 + pip + venv
#   Utilities      — jq, unzip, zip, xz-utils, file, sudo
#   SSH            — openssh-client (for actions that clone over SSH)
#
# Note: syslog forwarding is handled by the Mjolnir guest agent (vsock ch2),
# so no socat or busybox-syslogd is needed.

echo ""
echo "--- Installing CI packages ---"
chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    pkg-config \
    cmake \
    autoconf \
    automake \
    libtool \
    git \
    git-lfs \
    curl \
    wget \
    ca-certificates \
    nodejs \
    npm \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    unzip \
    zip \
    xz-utils \
    file \
    sudo \
    openssh-client \
    iproute2"

# ── Serial console autologin ─────────────────────────────────────────────────

mkdir -p "$R/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
chroot "$R" systemctl enable serial-getty@ttyS0.service

# ── Disable IPv6 ─────────────────────────────────────────────────────────────

cat > "$R/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# ── runner user ──────────────────────────────────────────────────────────────
#
# CI jobs run as "runner" (non-root) with passwordless sudo so actions that
# need to install packages or write to system paths can do so safely.

echo ""
echo "--- Creating runner user ---"
chroot "$R" useradd -m -s /bin/bash -G sudo runner
mkdir -p "$R/etc/sudoers.d"
echo 'runner ALL=(ALL) NOPASSWD:ALL' > "$R/etc/sudoers.d/runner"
chmod 440 "$R/etc/sudoers.d/runner"

# ── Workspace directories ─────────────────────────────────────────────────────
#
# /workspace/repo   — virtio-fs mounted (read-only) source tree from the host
# /workspace/cache  — virtio-fs mounted (read-write) action cache from the host
# /workspace/src    — local working directory for checked-out code
#
# The mount-extra-fs.sh script tries to mount the virtio-fs shares on boot.
# If they are not present (e.g., vanilla VM spawn) the directories still exist
# and jobs can use them as ordinary directories.

echo ""
echo "--- Creating workspace directories ---"
mkdir -p "$R/workspace/repo"
mkdir -p "$R/workspace/cache"
mkdir -p "$R/workspace/src"
# Inside the chroot: `runner` exists in the image's /etc/passwd, not the host's,
# so a host-side `chown runner:runner` fails with "invalid user" and set -e kills
# the build. (build-buzz-agent-image.sh sidesteps this by chowning numeric IDs.)
chroot "$R" chown -R runner:runner /workspace

# ── mount-extra-fs.sh ─────────────────────────────────────────────────────────
#
# Tries to mount known virtio-fs tags into /workspace at boot.
# Failures are non-fatal — the VM boots even if the host didn't attach shares.

cat > "$R/usr/local/bin/mount-extra-fs.sh" << 'MOUNTEOF'
#!/bin/bash
# Mount virtio-fs workspace shares from the host, if present.
# Called by mount-workspace.service on boot.

set -euo pipefail

mkdir -p /workspace/repo /workspace/cache

# Mount the repo share read-only (source tree injected by the runner).
if mount -t virtiofs repo /workspace/repo -o ro 2>/dev/null; then
    echo "mount-extra-fs: mounted virtiofs 'repo' at /workspace/repo (ro)"
fi

# Mount the cache share read-write (persistent action cache).
if mount -t virtiofs cache /workspace/cache 2>/dev/null; then
    echo "mount-extra-fs: mounted virtiofs 'cache' at /workspace/cache (rw)"
fi

exit 0
MOUNTEOF
chmod +x "$R/usr/local/bin/mount-extra-fs.sh"

# ── Systemd services ──────────────────────────────────────────────────────────
#
# Note: syslog forwarding is handled natively by the Mjolnir guest agent
# (binds /dev/log, forwards over vsock channel 2). No separate service needed.

echo ""
echo "--- Installing systemd services ---"

# mount-workspace: mount virtio-fs shares at boot
cp "$CI_ASSETS/mount-workspace.service" "$R/etc/systemd/system/mount-workspace.service"
chroot "$R" systemctl enable mount-workspace.service

# ── Guest agent ───────────────────────────────────────────────────────────────
#
# This script previously installed neither the binary nor the unit. The live
# @base/ci-ubuntu-24.04 boots only because both were added by hand months after
# it was built, so re-running this script used to emit an unbootable image
# (mjolnir-0e8). The helper installs both and verifies them.

install_guest_agent "$R"

# ── Network setup script ──────────────────────────────────────────────────────
#
# Called by the Mjolnir guest agent after the TAP interface is attached.

cat > "$R/usr/local/bin/mjolnir-network-setup" << 'NETEOF'
#!/bin/bash
# Configure the VM network interface. Called by the Mjolnir guest agent.
# Usage: mjolnir-network-setup <ip>
set -e

IP="${1:?Usage: mjolnir-network-setup <ip>}"

/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
/sbin/ip route add default dev eth0 2>/dev/null || true

echo "nameserver 8.8.8.8"   > /etc/resolv.conf
echo "nameserver 1.1.1.1"  >> /etc/resolv.conf

echo "Network configured: $IP"
NETEOF
chmod +x "$R/usr/local/bin/mjolnir-network-setup"

# ── APT cache cleanup ─────────────────────────────────────────────────────────

echo ""
echo "--- Cleaning apt caches ---"
chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get clean"
rm -rf "$R/var/lib/apt/lists/"*
rm -rf "$R/var/cache/apt/"*

# ── Done ──────────────────────────────────────────────────────────────────────

trap - EXIT

echo ""
echo "=== CI Rootfs Built ==="
echo "Subvolume: $OUTPUT"
echo "Size:      $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Use as base image:"
echo "  config :mjolnir, default_base_image: \"ci-ubuntu-24.04\""
echo ""
echo "Verify:"
echo "  btrfs subvolume show $OUTPUT"
