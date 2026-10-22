#!/bin/bash
set -euo pipefail

# Build a minimal Arch Linux BTRFS subvolume rootfs for Cloud Hypervisor VMs
# with virtio-fs. The output is a directory (BTRFS subvolume), not an ext4 file.
#
# Usage: sudo ./scripts/build-rootfs-arch.sh [output-path]
# Example: sudo ./scripts/build-rootfs-arch.sh /var/lib/mjolnir/btrfs/@base/arch
#
# On Arch hosts: uses pacstrap directly.
# On non-Arch hosts (e.g. Ubuntu): downloads the official Arch bootstrap tarball
# and uses it to run pacstrap — no host pacman installation needed.

OUTPUT="${1:-/var/lib/mjolnir/btrfs/@base/arch}"
AGENT_BIN="${AGENT_BIN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guest-agent.sh
source "$SCRIPT_DIR/lib/guest-agent.sh"
# shellcheck source=lib/terminfo.sh
source "$SCRIPT_DIR/lib/terminfo.sh"

ARCH_PACKAGES="base systemd dbus curl ca-certificates gnupg git iproute2 openssh jq base-devel openssl tmux cryptsetup kmod procps-ng"
ARCH_MIRROR="https://mirror.rackspace.com/archlinux"
BOOTSTRAP_URL="${ARCH_MIRROR}/iso/latest/archlinux-bootstrap-x86_64.tar.zst"

if [[ -z "$AGENT_BIN" ]]; then
    for path in \
        "./native/target/x86_64-unknown-linux-musl/release/mjolnir-agent" \
        "../native/target/x86_64-unknown-linux-musl/release/mjolnir-agent" \
        "./native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent" \
        "../native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    do
        if [[ -f "$path" ]]; then
            AGENT_BIN="$path"
            break
        fi
    done
fi

echo "=== Building Arch Linux Rootfs (BTRFS subvolume) ==="
echo "Output: $OUTPUT"
echo "Agent: ${AGENT_BIN:-NOT FOUND}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (need pacstrap, btrfs)"
    exit 1
fi

if ! command -v pacstrap &>/dev/null; then
    echo "Error: pacstrap not found. Install arch-install-scripts."
    exit 1
fi

# ─── Bootstrap logic ──────────────────────────────────────────────────────────
# On Arch, pacman is on the host and pacstrap just works.
# On Ubuntu/Debian, pacstrap is available but pacman is not — we need the
# Arch bootstrap tarball so we can run pacman from inside a real Arch chroot.

BOOTSTRAP_DIR=""

cleanup_bootstrap() {
    if [[ -n "$BOOTSTRAP_DIR" && -d "$BOOTSTRAP_DIR" ]]; then
        umount "$BOOTSTRAP_DIR/mnt" 2>/dev/null || true
        umount "$BOOTSTRAP_DIR"    2>/dev/null || true
        rm -rf "$BOOTSTRAP_DIR"
    fi
}

do_pacstrap() {
    local target="$1"

    if command -v pacman &>/dev/null; then
        echo "--- Bootstrapping via host pacstrap ---"
        # shellcheck disable=SC2086
        pacstrap -c "$target" $ARCH_PACKAGES
    else
        echo "--- pacman not on host — downloading Arch bootstrap tarball ---"
        BOOTSTRAP_DIR="$(mktemp -d /tmp/arch-bootstrap-XXXXXX)"
        trap cleanup_bootstrap EXIT

        local tarball="/tmp/archlinux-bootstrap-$$.tar.zst"
        echo "Downloading: $BOOTSTRAP_URL"
        curl -fsSL --connect-timeout 30 "$BOOTSTRAP_URL" -o "$tarball"

        echo "Extracting bootstrap..."
        # Tarball contains root.x86_64/ at the top level — strip it
        tar -xf "$tarball" --use-compress-program=unzstd -C "$BOOTSTRAP_DIR" \
            --strip-components=1 2>/dev/null || \
        tar --zstd -xf "$tarball" -C "$BOOTSTRAP_DIR" --strip-components=1
        rm -f "$tarball"

        # Configure a mirror
        echo "Server = ${ARCH_MIRROR}/\$repo/os/\$arch" \
            > "$BOOTSTRAP_DIR/etc/pacman.d/mirrorlist"

        # arch-chroot needs the dir to be a mount point
        mount --bind "$BOOTSTRAP_DIR" "$BOOTSTRAP_DIR"

        # Initialize pacman keyring inside bootstrap
        echo "Initializing pacman keyring..."
        arch-chroot "$BOOTSTRAP_DIR" pacman-key --init
        arch-chroot "$BOOTSTRAP_DIR" pacman-key --populate archlinux

        # Bind-mount the output subvolume so bootstrap's pacstrap can write into it
        mkdir -p "$BOOTSTRAP_DIR/mnt"
        mount --bind "$target" "$BOOTSTRAP_DIR/mnt"

        echo "--- Bootstrapping via Arch bootstrap tarball ---"
        # shellcheck disable=SC2086
        arch-chroot "$BOOTSTRAP_DIR" pacstrap -c /mnt $ARCH_PACKAGES

        umount "$BOOTSTRAP_DIR/mnt"
        umount "$BOOTSTRAP_DIR"
        rm -rf "$BOOTSTRAP_DIR"
        BOOTSTRAP_DIR=""
        trap - EXIT
    fi
}

# ─── Main build ───────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$OUTPUT")"

if [[ -d "$OUTPUT" ]]; then
    echo "Removing existing subvolume..."
    btrfs subvolume delete "$OUTPUT" 2>/dev/null || rm -rf "$OUTPUT"
fi

echo "Creating BTRFS subvolume..."
btrfs subvolume create "$OUTPUT"

do_pacstrap "$OUTPUT"

# Locale
echo "en_US.UTF-8 UTF-8" >> "$OUTPUT/etc/locale.gen"
echo "LANG=en_US.UTF-8" > "$OUTPUT/etc/locale.conf"
arch-chroot "$OUTPUT" locale-gen

# Hostname + hosts
echo "arch-vm" > "$OUTPUT/etc/hostname"
cat > "$OUTPUT/etc/hosts" << 'EOF'
127.0.0.1 localhost arch-vm
::1 localhost
EOF

# Fstab for virtio-fs: tag "myfs" must match CH fs_config and boot_args
cat > "$OUTPUT/etc/fstab" << 'EOF'
myfs / virtiofs rw 0 0
EOF

# Serial console autologin
mkdir -p "$OUTPUT/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$OUTPUT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
arch-chroot "$OUTPUT" systemctl enable serial-getty@ttyS0.service

arch-chroot "$OUTPUT" passwd -l root

# Guest agent. Fail closed (mjolnir-0e8); set ALLOW_NO_AGENT=1 to skip.
install_guest_agent "$OUTPUT"
install_ghostty_terminfo "$OUTPUT"

# Network setup script (called by guest agent)
cat > "$OUTPUT/usr/local/bin/mjolnir-network-setup" << 'NETEOF'
#!/bin/bash
set -e
IP="$1"
if [[ -z "$IP" ]]; then
    echo "Usage: mjolnir-network-setup <ip>" >&2
    exit 1
fi
IFACE=$(ls /sys/class/net | grep -v lo | head -1)
if [[ -z "$IFACE" ]]; then
    echo "Error: no network interface found" >&2
    exit 1
fi
/sbin/ip addr add "${IP}/32" dev "$IFACE" 2>/dev/null || true
/sbin/ip link set "$IFACE" up
/sbin/ip route add default dev "$IFACE" 2>/dev/null || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "Network configured: $IP on $IFACE"
NETEOF
chmod +x "$OUTPUT/usr/local/bin/mjolnir-network-setup"

# Snapshot trigger helper
cat > "$OUTPUT/usr/local/bin/mjolnir-snapshot" << 'SNAPEOF'
#!/bin/bash
set -euo pipefail
VM_INFO_FILE="/etc/mjolnir/vm.json"
if [[ ! -f "$VM_INFO_FILE" ]]; then
    echo "Error: VM identity not configured ($VM_INFO_FILE not found)" >&2
    exit 1
fi
VM_ID=$(jq -r .vm_id "$VM_INFO_FILE")
API_URL=$(jq -r .api_url "$VM_INFO_FILE")
NAME="${1:?Usage: mjolnir-snapshot <name>}"
echo "Creating snapshot '$NAME' of VM $VM_ID..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/vms/$VM_ID/snapshots" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$NAME\"}")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "Snapshot '$NAME' created successfully."
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
else
    echo "Error creating snapshot (HTTP $HTTP_CODE):" >&2
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY" >&2
    exit 1
fi
SNAPEOF
chmod +x "$OUTPUT/usr/local/bin/mjolnir-snapshot"

# Disable IPv6
cat > "$OUTPUT/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# sshd
cat > "$OUTPUT/etc/ssh/sshd_config.d/mjolnir.conf" << 'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
mkdir -p "$OUTPUT/root/.ssh"
chmod 700 "$OUTPUT/root/.ssh"
arch-chroot "$OUTPUT" systemctl enable sshd.service

# mise
arch-chroot "$OUTPUT" /bin/bash -c "curl -fsSL https://mise.run | sh"
cat >> "$OUTPUT/root/.bashrc" << 'EOF'

eval "$(/root/.local/bin/mise activate bash)"
EOF
cat > "$OUTPUT/etc/profile.d/mise.sh" << 'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
EOF

arch-chroot "$OUTPUT" pacman -Scc --noconfirm

echo ""
echo "=== Rootfs Built ==="
echo "Subvolume: $OUTPUT"
echo "Size: $(du -sh "$OUTPUT" | cut -f1)"
echo "Verify: btrfs subvolume show $OUTPUT"
