#!/bin/bash
set -euo pipefail

# Build a minimal Ubuntu 24.04 BTRFS subvolume rootfs for Cloud Hypervisor VMs
# with virtio-fs. The output is a directory (BTRFS subvolume), not an ext4 file.
#
# Usage: sudo ./scripts/build-rootfs.sh [output-path]
# Example: sudo ./scripts/build-rootfs.sh /var/lib/mjolnir/btrfs/@base/ubuntu-24.04

OUTPUT="${1:-/var/lib/mjolnir/btrfs/@base/ubuntu-24.04}"
AGENT_BIN="${AGENT_BIN:-}"

# Find agent binary
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

echo "=== Building Ubuntu 24.04 Rootfs (BTRFS subvolume) ==="
echo "Output: $OUTPUT"
echo "Agent: ${AGENT_BIN:-NOT FOUND}"
echo ""

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (need debootstrap, btrfs)"
    exit 1
fi

# Ensure parent directory exists
mkdir -p "$(dirname "$OUTPUT")"

# Remove existing subvolume if present
if [[ -d "$OUTPUT" ]]; then
    echo "Removing existing subvolume..."
    btrfs subvolume delete "$OUTPUT" 2>/dev/null || rm -rf "$OUTPUT"
fi

# Create BTRFS subvolume (the subvolume IS the rootfs directory)
echo "Creating BTRFS subvolume..."
btrfs subvolume create "$OUTPUT"

# The subvolume is our mount/work directory — no mount needed
MOUNT_DIR="$OUTPUT"

cleanup() {
    echo "Cleaning up..."
    # No umount needed — subvolume is a directory, not a mounted image
}
trap cleanup EXIT

# Bootstrap
echo "Bootstrapping Ubuntu 24.04 Noble..."
debootstrap --variant=minbase \
    --include=systemd,systemd-sysv,dbus,procps,curl,ca-certificates,gpg,git,iproute2,openssh-server,jq \
    noble "$MOUNT_DIR" http://archive.ubuntu.com/ubuntu

# Basic config
echo "mjolnir-vm" > "$MOUNT_DIR/etc/hostname"
cat > "$MOUNT_DIR/etc/hosts" << 'EOF'
127.0.0.1 localhost mjolnir-vm
::1 localhost
EOF

# Fstab for virtio-fs: tag "myfs" must match CH fs_config and boot_args
cat > "$MOUNT_DIR/etc/fstab" << 'EOF'
myfs / virtiofs rw 0 0
EOF

# Serial console
mkdir -p "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
chroot "$MOUNT_DIR" systemctl enable serial-getty@ttyS0.service

# Lock root password (serial console uses autologin, SSH uses key auth)
chroot "$MOUNT_DIR" passwd -l root

# Guest agent
if [[ -n "$AGENT_BIN" && -f "$AGENT_BIN" ]]; then
    echo "Installing guest agent..."
    cp "$AGENT_BIN" "$MOUNT_DIR/usr/local/bin/mjolnir-agent"
    chmod +x "$MOUNT_DIR/usr/local/bin/mjolnir-agent"

    mkdir -p "$MOUNT_DIR/etc/mjolnir"
    chmod 700 "$MOUNT_DIR/etc/mjolnir"

    cat > "$MOUNT_DIR/etc/systemd/system/mjolnir-agent.service" << 'EOF'
[Unit]
Description=Mjolnir Guest Agent
After=sysinit.target
Wants=sysinit.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mjolnir-agent
Restart=on-failure
RestartSec=2
StartLimitBurst=3
StartLimitIntervalSec=30

[Install]
WantedBy=basic.target
EOF
    mkdir -p "$MOUNT_DIR/etc/systemd/system/basic.target.wants"
    chroot "$MOUNT_DIR" ln -sf /etc/systemd/system/mjolnir-agent.service /etc/systemd/system/basic.target.wants/mjolnir-agent.service
else
    echo "WARNING: No guest agent - vsock commands won't work"
fi

# Network setup script (called by guest agent)
echo "Installing network setup script..."
cat > "$MOUNT_DIR/usr/local/bin/mjolnir-network-setup" << 'NETEOF'
#!/bin/bash
# Called by guest agent with: $1=ip (e.g., 10.200.45.123)
set -e
IP="$1"

if [[ -z "$IP" ]]; then
    echo "Usage: mjolnir-network-setup <ip>" >&2
    exit 1
fi

/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
/sbin/ip route add default dev eth0 2>/dev/null || true

echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "Network configured: $IP"
NETEOF
chmod +x "$MOUNT_DIR/usr/local/bin/mjolnir-network-setup"

# Snapshot trigger helper
echo "Installing mjolnir-snapshot helper..."
cat > "$MOUNT_DIR/usr/local/bin/mjolnir-snapshot" << 'SNAPEOF'
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
chmod +x "$MOUNT_DIR/usr/local/bin/mjolnir-snapshot"

# Enable universe repo
echo "Configuring apt repositories..."
cat > "$MOUNT_DIR/etc/apt/sources.list.d/ubuntu.sources" << 'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# Install packages
echo "Installing system packages..."
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential libssl-dev libffi-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev \
    pkg-config tmux cryptsetup-bin kmod"

# Install mise
echo "Installing mise version manager..."
chroot "$MOUNT_DIR" /bin/bash -c "curl -fsSL https://mise.run | sh"
cat >> "$MOUNT_DIR/root/.bashrc" << 'EOF'

# mise — version manager for dev toolchains
eval "$(/root/.local/bin/mise activate bash)"
EOF
cat > "$MOUNT_DIR/etc/profile.d/mise.sh" << 'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
EOF

# Disable IPv6
echo "Disabling IPv6..."
cat > "$MOUNT_DIR/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# Configure sshd
echo "Configuring sshd..."
cat > "$MOUNT_DIR/etc/ssh/sshd_config.d/mjolnir.conf" << 'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF

mkdir -p "$MOUNT_DIR/root/.ssh"
chmod 700 "$MOUNT_DIR/root/.ssh"
chroot "$MOUNT_DIR" systemctl enable ssh

# Cleanup apt cache
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get clean"
rm -rf "$MOUNT_DIR/var/lib/apt/lists/"*
rm -rf "$MOUNT_DIR/var/cache/apt/"*

# Done — no umount needed
trap - EXIT

echo ""
echo "=== Rootfs Built ==="
echo "Subvolume: $OUTPUT"
echo "Size: $(du -sh "$OUTPUT" | cut -f1)"
echo "Verify: btrfs subvolume show $OUTPUT"
