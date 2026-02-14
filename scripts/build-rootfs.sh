#!/bin/bash
set -euo pipefail

# Build a minimal Ubuntu 24.04 ext4 rootfs image for Firecracker microVMs
# Includes mise (universal version manager) for Node.js, Python, Rust, etc.
#
# Usage: ./build-rootfs.sh [output-path] [size-mb]
# Example: ./build-rootfs.sh /tmp/ubuntu-24.04.ext4 512
# sudo ./scripts/build-rootfs.sh /var/lib/mjolnir/btrfs/@base/ubuntu-24.04.ext4

OUTPUT="${1:-ubuntu-24.04.ext4}"
SIZE_MB="${2:-8192}"
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

echo "=== Building Ubuntu 24.04 Rootfs ==="
echo "Output: $OUTPUT"
echo "Size: ${SIZE_MB}MB"
echo "Agent: ${AGENT_BIN:-NOT FOUND}"
echo ""

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (need mount, debootstrap)"
    exit 1
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

# Create sparse ext4 image
echo "Creating ext4 image..."
rm -f "$OUTPUT"
dd if=/dev/zero of="$OUTPUT" bs=1M count=0 seek="$SIZE_MB" 2>/dev/null
mkfs.ext4 -q "$OUTPUT"

# Mount
MOUNT_DIR=$(mktemp -d)
mount -o loop "$OUTPUT" "$MOUNT_DIR"

cleanup() {
    echo "Cleaning up..."
    umount "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
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

cat > "$MOUNT_DIR/etc/fstab" << 'EOF'
/dev/vda / ext4 defaults 0 1
EOF

# Serial console
mkdir -p "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
chroot "$MOUNT_DIR" systemctl enable serial-getty@ttyS0.service

# Root password
echo "root:mjolnir" | chroot "$MOUNT_DIR" chpasswd

# Guest agent
if [[ -n "$AGENT_BIN" && -f "$AGENT_BIN" ]]; then
    echo "Installing guest agent..."
    cp "$AGENT_BIN" "$MOUNT_DIR/usr/local/bin/mjolnir-agent"
    chmod +x "$MOUNT_DIR/usr/local/bin/mjolnir-agent"

    # Create mjolnir config directory (for optional pre-generated Iroh keys)
    mkdir -p "$MOUNT_DIR/etc/mjolnir"
    chmod 700 "$MOUNT_DIR/etc/mjolnir"

    # Create service file - start early in boot (after sysinit.target)
    # This ensures the agent is available before multi-user.target which
    # can wait on serial-getty and other services that delay boot
    cat > "$MOUNT_DIR/etc/systemd/system/mjolnir-agent.service" << 'EOF'
[Unit]
Description=Mjolnir Guest Agent
After=sysinit.target
Wants=sysinit.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mjolnir-agent
Restart=always
RestartSec=1

[Install]
WantedBy=basic.target
EOF
    # Enable in basic.target.wants so it starts early
    mkdir -p "$MOUNT_DIR/etc/systemd/system/basic.target.wants"
    chroot "$MOUNT_DIR" ln -sf /etc/systemd/system/mjolnir-agent.service /etc/systemd/system/basic.target.wants/mjolnir-agent.service
else
    echo "WARNING: No guest agent - vsock commands won't work"
fi

# Network setup script (called by guest agent)
# Uses point-to-point routing - no gateway IP needed
echo "Installing network setup script..."
cat > "$MOUNT_DIR/usr/local/bin/mjolnir-network-setup" << 'NETEOF'
#!/bin/bash
# Called by guest agent with: $1=ip (e.g., 10.200.45.123)
# Point-to-point link - default route goes directly via eth0
set -e
IP="$1"

if [[ -z "$IP" ]]; then
    echo "Usage: mjolnir-network-setup <ip>" >&2
    exit 1
fi

# Configure IP on eth0 (point-to-point, /32)
/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up

# Point-to-point default route (no gateway needed)
/sbin/ip route add default dev eth0 2>/dev/null || true

# DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "Network configured: $IP"
NETEOF
chmod +x "$MOUNT_DIR/usr/local/bin/mjolnir-network-setup"

# Snapshot trigger helper (calls host API to create snapshot)
echo "Installing mjolnir-snapshot helper..."
cat > "$MOUNT_DIR/usr/local/bin/mjolnir-snapshot" << 'SNAPEOF'
#!/bin/bash
# Create a snapshot of this VM from inside the guest.
# Usage: mjolnir-snapshot <name>
#
# Reads VM identity from /etc/mjolnir/vm.json (injected by host during boot)
# and calls the host API to trigger a consistent snapshot.

set -euo pipefail

VM_INFO_FILE="/etc/mjolnir/vm.json"

if [[ ! -f "$VM_INFO_FILE" ]]; then
    echo "Error: VM identity not configured ($VM_INFO_FILE not found)" >&2
    echo "This VM may not have been started by Mjolnir." >&2
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

# Enable universe repo for broader package availability
echo "Configuring apt repositories..."
cat > "$MOUNT_DIR/etc/apt/sources.list.d/ubuntu.sources" << 'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# Install essential packages
echo "Installing system packages..."
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential libssl-dev libffi-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev \
    pkg-config"

# Install mise — universal version manager for Node, Python, Rust, Go, etc.
# Runs as root here; users interact via `mise install node@22` etc.
echo "Installing mise version manager..."
chroot "$MOUNT_DIR" /bin/bash -c "curl -fsSL https://mise.run | sh"
# Activate mise for all bash sessions
cat >> "$MOUNT_DIR/root/.bashrc" << 'EOF'

# mise — version manager for dev toolchains
eval "$(/root/.local/bin/mise activate bash)"
EOF
# Also put it on PATH for non-interactive shells (e.g. exec via agent)
cat > "$MOUNT_DIR/etc/profile.d/mise.sh" << 'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
EOF

# Disable IPv6 system-wide
# Iroh tries IPv6 first, but we don't have routable IPv6, causing hangs
echo "Disabling IPv6..."
cat > "$MOUNT_DIR/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
# Disable IPv6 - we use IPv4 with NAT for simplicity
# Without this, Iroh hangs trying IPv6 relay connections
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# Configure sshd for key-only authentication
echo "Configuring sshd..."
cat > "$MOUNT_DIR/etc/ssh/sshd_config.d/mjolnir.conf" << 'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF

# Create /root/.ssh directory (keys injected at runtime by guest agent)
mkdir -p "$MOUNT_DIR/root/.ssh"
chmod 700 "$MOUNT_DIR/root/.ssh"

# Enable sshd (starts on boot, but rejects connections until keys are injected)
chroot "$MOUNT_DIR" systemctl enable ssh

# Cleanup apt cache
chroot "$MOUNT_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get clean"
rm -rf "$MOUNT_DIR/var/lib/apt/lists/"*
rm -rf "$MOUNT_DIR/var/cache/apt/"*

# Done
trap - EXIT
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo ""
echo "=== Rootfs Built ==="
echo "File: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
