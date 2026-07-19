#!/bin/bash
set -euo pipefail

# Build a "deploy-node-bun" Ubuntu 24.04 BTRFS subvolume rootfs for Mjolnir
# deploy-build VMs (mjolnir-gge.1.10).
#
# This image is the ephemeral-build base for Mjolnir.Deploy.Builder: it ships
# with mise, node@20, and bun preinstalled and on PATH so a deploy build can
# run `mise install && bun install && bun run build` (or the npm/pnpm/yarn
# equivalents from Mjolnir.Deploy.Detector) with NO per-build toolchain
# install step. That removes two costs from every deploy build:
#
#   1. ~30s+ of `apt-get install nodejs` + `curl | bash` bun install on every
#      cold build.
#   2. The bun standalone-installer's `HOME: unbound variable` failure —
#      Mjolnir.Deploy.Builder execs steps over vsock via a bare (non-login)
#      shell, which does not source /etc/profile or set $HOME the way an
#      interactive login shell does. `curl -fsSL https://bun.sh/install | bash`
#      hard-requires $HOME to be set and unset -u trips it. Baking the
#      toolchain into the image at build time (where we fully control the
#      environment) sidesteps that failure mode entirely — no installer runs
#      during a deploy build at all.
#
# Structure mirrors scripts/build-ci-image.sh: debootstrap --variant=minbase,
# a BTRFS subvolume as rootfs (no loop-mount), the same virtiofs root fstab
# entry, the same mount-extra-fs.sh / mount-workspace.service pattern for
# virtio-fs workspace shares, and the same mjolnir-network-setup script for
# the guest agent to configure networking post-boot. Do not reinvent that
# plumbing here — copy/adjust it the way this script does if it changes.
#
# Usage: sudo ./scripts/build-deploy-base.sh [output-path]
# Example: sudo ./scripts/build-deploy-base.sh /var/lib/mjolnir/btrfs/@base/deploy-node-bun
#
# The script is idempotent: if the subvolume already exists it is deleted and
# recreated from scratch.
#
# Prerequisites (on the server):
#   apt-get install -y debootstrap btrfs-progs
#
# Intended `just` recipe (NOT added here — this repo's Justfile is owned by
# another lane; add something like this alongside `build-ci-image`):
#
#   # Build deploy base image on the server (@base/deploy-node-bun)
#   build-deploy-base: _require-host
#       ssh {{host}} "cd /opt/mjolnir && sudo bash scripts/build-deploy-base.sh /var/lib/mjolnir/btrfs/@base/deploy-node-bun"
#
# Deploy-lane wiring this base image still needs (out of scope for this
# script — lib/ is owned by another lane, noted here for the deploy lane):
#   - Mjolnir.Deploy.Builder.build/3 takes `:base_image` in `opts`, defaulting
#     to `base_layer_id` (see lib/mjolnir/deploy/builder.ex ~line 102). Nothing
#     in lib/mjolnir/deploy/ currently passes `base_layer_id: "deploy-node-bun"`
#     (grepped — no hits for "deploy-node-bun" or a deploy-specific base image
#     name anywhere under lib/). Whatever calls `Builder.build/3` for the
#     deploy lane (Deploy.Supervisor or its caller) needs to pass
#     `base_layer_id: "deploy-node-bun"` (or `base_image:` override) instead of
#     falling through to the VM.spawn default of `"ubuntu-24.04"`
#     (lib/mjolnir/cloud_hypervisor/config.ex:19), or none of this image is
#     ever used.
#   - Mjolnir.Deploy.Detector's build_plan/1 already emits `"mise install"` as
#     the first step (lib/mjolnir/deploy/detector.ex:77) — that step is a
#     no-op / fast-path once mise + node@20 + bun are baked in, as long as a
#     `.tool-versions` or `mise.toml` pins the same versions this image
#     installs (node@20). If the app's mise config asks for a different node
#     minor/bun version than what's baked in, `mise install` will still fetch
#     it (mise is on PATH, network permitting) — just no longer for the
#     common case.

OUTPUT="${1:-/var/lib/mjolnir/btrfs/@base/deploy-node-bun}"

# The directory this script lives in — used to locate the ci-image/ assets
# (reused as-is; the deploy base needs the same virtiofs mount plumbing).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ASSETS="$SCRIPT_DIR/ci-image"

# Toolchain versions baked into the image. Keep in sync with
# lib/mjolnir/deploy/detector.ex's @runtime ("node@20").
NODE_VERSION="20"
BUN_VERSION="latest"

echo "=== Building Deploy Node+Bun Rootfs (BTRFS subvolume) ==="
echo "Output:     $OUTPUT"
echo "Assets dir: $CI_ASSETS"
echo "Toolchain:  mise, node@${NODE_VERSION}, bun@${BUN_VERSION}"
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

echo "deploy-builder" > "$R/etc/hostname"

cat > "$R/etc/hosts" << 'EOF'
127.0.0.1 localhost deploy-builder
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

# ── Base packages ─────────────────────────────────────────────────────────────
#
# Deliberately NOT installing `nodejs`/`npm` from apt — mise manages node so
# the version matches Mjolnir.Deploy.Detector's @runtime exactly, and bun has
# no apt package at all. This is the whole point of the image: no per-build
# `apt-get install nodejs` / `curl | bash` bun install.
#
#   Build tools — compilers + headers (native npm/bun module builds)
#   VCS         — git (lockfile/source checkout, package manager git deps)
#   Network     — curl, ca-certificates (mise's own installer + tool downloads)
#   Utilities   — jq, unzip, xz-utils (mise/bun release archives), file, sudo

echo ""
echo "--- Installing base packages ---"
chroot "$R" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    pkg-config \
    git \
    curl \
    ca-certificates \
    jq \
    unzip \
    xz-utils \
    file \
    sudo \
    iproute2"

# ── mise + node + bun ──────────────────────────────────────────────────────────
#
# Installed for root, matching this repo's own convention (see the
# `deploy-boot` just recipe: `$HOME/.local/bin/mise activate bash`) rather
# than a separate build user — deploy build steps are exec'd over vsock with
# no guarantee of *which* shell/user runs them, so root + a fully-qualified
# PATH is the safest common denominator for this P0 image.
#
# `HOME=/root` is passed explicitly on every invocation below rather than
# relied upon from the ambient chroot environment — this is exactly the class
# of bug this image exists to eliminate, so the build script practices what
# it preaches.
#
# After install, the mise-managed node/npm/npx/bun/bunx shims are symlinked
# into /usr/local/bin. That is deliberate belt-and-suspenders: mise shims only
# resolve via `~/.local/share/mise/shims` being on $PATH, which normally comes
# from shell activation (`mise activate`) in an interactive/login shell.
# Mjolnir.Deploy.Builder execs build steps as bare commands over vsock — there
# is no guarantee that shell activation runs — so /usr/local/bin (which is on
# PATH unconditionally for every shell flavor, login or not) is the
# reliable path. /etc/environment is also set for the login-shell case
# (e.g. interactive debugging over SSH/console).

echo ""
echo "--- Installing mise ---"
chroot "$R" /bin/bash -c "HOME=/root curl -fsSL https://mise.run | HOME=/root MISE_INSTALL_PATH=/root/.local/bin/mise sh"

echo ""
echo "--- Installing node@${NODE_VERSION} + bun@${BUN_VERSION} via mise ---"
chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise install node@${NODE_VERSION} bun@${BUN_VERSION}"
chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise use -g node@${NODE_VERSION} bun@${BUN_VERSION}"
chroot "$R" /bin/bash -c "HOME=/root /root/.local/bin/mise reshim"

echo ""
echo "--- Symlinking toolchain into /usr/local/bin (PATH-independent of shell activation) ---"
for bin in mise node npm npx bun bunx; do
    src=""
    if [[ -x "$R/root/.local/bin/$bin" ]]; then
        src="/root/.local/bin/$bin"
    elif [[ -x "$R/root/.local/share/mise/shims/$bin" ]]; then
        src="/root/.local/share/mise/shims/$bin"
    fi

    if [[ -n "$src" ]]; then
        ln -sf "$src" "$R/usr/local/bin/$bin"
    else
        echo "Warning: $bin not found after mise install — skipping symlink"
    fi
done

# HOME + PATH for interactive/login shells (mise shims dir first so a session
# that explicitly wants the mise-managed version wins over the /usr/local/bin
# symlink fallback).
cat > "$R/etc/environment" << 'EOF'
HOME="/root"
PATH="/root/.local/share/mise/shims:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

# ── Verify the toolchain resolves inside the chroot ─────────────────────────

echo ""
echo "--- Verifying toolchain ---"
chroot "$R" /bin/bash -c "HOME=/root PATH=/usr/local/bin:\$PATH node --version && npm --version && bun --version && /root/.local/bin/mise --version"

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

# ── Workspace directories ─────────────────────────────────────────────────────
#
# /workspace/repo  — virtio-fs mounted (read-only) app source tree from host
# /workspace/cache — virtio-fs mounted (read-write) build/package cache
# /app             — Mjolnir.Deploy.Runtime's @default_workdir; build steps
#                     run against whatever lands here (source injection into
#                     the build VM is owned by the deploy lane, not this
#                     image — this just makes sure the directory exists with
#                     sane ownership).

echo ""
echo "--- Creating workspace directories ---"
mkdir -p "$R/workspace/repo"
mkdir -p "$R/workspace/cache"
mkdir -p "$R/app"

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

# Mount the cache share read-write (persistent build/package cache).
if mount -t virtiofs cache /workspace/cache 2>/dev/null; then
    echo "mount-extra-fs: mounted virtiofs 'cache' at /workspace/cache (rw)"
fi

exit 0
MOUNTEOF
chmod +x "$R/usr/local/bin/mount-extra-fs.sh"

# ── Systemd services ──────────────────────────────────────────────────────────

echo ""
echo "--- Installing systemd services ---"

# mount-workspace: mount virtio-fs shares at boot (same unit as the CI image).
cp "$CI_ASSETS/mount-workspace.service" "$R/etc/systemd/system/mount-workspace.service"
chroot "$R" systemctl enable mount-workspace.service

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
echo "=== Deploy Node+Bun Rootfs Built ==="
echo "Subvolume: $OUTPUT"
echo "Size:      $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Use as base image (deploy lane wiring, not this script — see header):"
echo "  Mjolnir.Deploy.Builder.build(base_layer_id, steps, base_layer_id: \"deploy-node-bun\")"
echo ""
echo "Verify:"
echo "  btrfs subvolume show $OUTPUT"
