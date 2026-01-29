# Mjolnir development commands
# Install just: cargo install just
# Run: just <recipe>  or  just --list

# Default recipe - show available commands
default:
    @just --list

# ============================================================================
# Guest Agent
# ============================================================================

# Build the guest agent (static musl binary for any Linux)
build-agent:
    #!/usr/bin/env bash
    set -euo pipefail
    cd native/mjolnir_guest_agent
    echo "Building guest agent (musl static binary)..."
    cargo build --release --target x86_64-unknown-linux-musl
    ls -lh target/x86_64-unknown-linux-musl/release/mjolnir-agent
    echo "✓ Agent built: target/x86_64-unknown-linux-musl/release/mjolnir-agent"

# Why musl? Creates a fully static binary (~1.5MB) that runs on ANY Linux
# regardless of libc version. No runtime dependencies, fast startup.
# If you get "target not found": rustup target add x86_64-unknown-linux-musl

# ============================================================================
# Rootfs
# ============================================================================

# Build the Debian 12 rootfs (requires sudo)
build-rootfs:
    #!/usr/bin/env bash
    set -euo pipefail
    AGENT="native/mjolnir_guest_agent/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
    if [[ ! -f "$AGENT" ]]; then
        echo "Error: Guest agent not built. Run: just build-agent"
        exit 1
    fi
    echo "Building Debian 12 rootfs (requires sudo)..."
    sudo AGENT_BIN="$AGENT" ./scripts/build-rootfs.sh \
        /var/lib/mjolnir/btrfs/@base/debian-12.ext4 512
    echo "✓ Rootfs built"

    # Also sync to test environment
    if [[ -d "/var/lib/mjolnir/btrfs/@base-test" ]]; then
        echo "Syncing to test environment..."
        sudo cp --reflink=auto /var/lib/mjolnir/btrfs/@base/debian-12.ext4 \
            /var/lib/mjolnir/btrfs/@base-test/debian-12.ext4
        echo "✓ Test rootfs synced"
    fi

# Build both agent and rootfs
build-all: build-agent build-rootfs

# Sync base image to test environment (after rebuilding rootfs)
sync-test-rootfs:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="/var/lib/mjolnir/btrfs/@base/debian-12.ext4"
    DST="/var/lib/mjolnir/btrfs/@base-test/debian-12.ext4"
    if [[ -f "$SRC" ]]; then
        echo "Syncing base image to test environment..."
        sudo cp --reflink=auto "$SRC" "$DST"
        echo "✓ Test rootfs updated"
    else
        echo "Error: Base image not found at $SRC"
        exit 1
    fi

# ============================================================================
# Networking
# ============================================================================

# Set up host networking for VM internet access (requires sudo)
setup-networking:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Setting up VM networking..."

    # IP forwarding
    sudo sysctl -w net.ipv4.ip_forward=1

    # NAT for VM subnet (10.200.0.0/10 = ~4M VMs)
    sudo iptables -t nat -C POSTROUTING -s 10.200.0.0/10 -j MASQUERADE 2>/dev/null || \
        sudo iptables -t nat -A POSTROUTING -s 10.200.0.0/10 -j MASQUERADE

    # Allow forwarding
    sudo iptables -C FORWARD -s 10.200.0.0/10 -j ACCEPT 2>/dev/null || \
        sudo iptables -A FORWARD -s 10.200.0.0/10 -j ACCEPT
    sudo iptables -C FORWARD -d 10.200.0.0/10 -j ACCEPT 2>/dev/null || \
        sudo iptables -A FORWARD -d 10.200.0.0/10 -j ACCEPT

    echo "✓ Networking configured"
    echo "  NAT: 10.200.0.0/10 → MASQUERADE"
    echo "  Forwarding: enabled"

# Show current networking status
networking-status:
    #!/usr/bin/env bash
    echo "=== IP Forwarding ==="
    cat /proc/sys/net/ipv4/ip_forward
    echo ""
    echo "=== NAT Rules ==="
    sudo iptables -t nat -L POSTROUTING -v | grep -E "10.200|Chain" || echo "(none)"
    echo ""
    echo "=== Forward Rules ==="
    sudo iptables -L FORWARD -v | grep -E "10.200|Chain" || echo "(none)"
    echo ""
    echo "=== TAP Interfaces ==="
    ip link show | grep "mj-" || echo "(none running)"

# ============================================================================
# Testing
# ============================================================================

# Run unit tests (no root required)
test:
    mix test --exclude integration

# Run all tests including integration (requires sudo + built rootfs)
test-all:
    #!/usr/bin/env bash
    MIX_PATH="$(which mix)"
    sudo bash -c "eval \"\$(mise activate bash)\" && mix test --include integration"

# Run network-specific tests
test-network:
    mix test test/mjolnir/network_test.exs

# Run VM integration tests (requires sudo)
test-vm:
    #!/usr/bin/env bash
    sudo bash -c "eval \"\$(mise activate bash)\" && cd {{justfile_directory()}} && mix test --include integration test/mjolnir/vm_test.exs"

# Run Iroh shell tests (requires sudo)
test-iroh:
    #!/usr/bin/env bash
    sudo bash -c "eval \"\$(mise activate bash)\" && cd {{justfile_directory()}} && mix test --include integration test/mjolnir/vm_iroh_test.exs"

# ============================================================================
# Development
# ============================================================================

# Start IEx with Mjolnir loaded
iex:
    iex -S mix

# Start IEx as root (required for VM operations)
iex-root:
    #!/usr/bin/env bash
    sudo bash -c "eval \"\$(mise activate bash)\" && cd {{justfile_directory()}} && iex -S mix"

# Compile the project
compile:
    mix compile

# Format all Elixir code
format:
    mix format

# Clean build artifacts
clean:
    mix clean
    cd native/mjolnir_guest_agent && cargo clean

# ============================================================================
# Quick Start
# ============================================================================

# Full setup from scratch (run once on new machine)
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Mjolnir Bootstrap ==="
    echo ""
    echo "This will:"
    echo "  1. Build the guest agent"
    echo "  2. Build the rootfs (requires sudo)"
    echo "  3. Set up networking (requires sudo)"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    just build-agent
    just build-rootfs
    just setup-networking
    echo ""
    echo "✓ Bootstrap complete!"
    echo ""
    echo "Test with:"
    echo "  just iex-root"
    echo "  {:ok, vm} = Mjolnir.VM.spawn()"
    echo "  Mjolnir.VM.exec(vm.id, \"curl -s https://example.com | head -3\")"

# ============================================================================
# Debugging
# ============================================================================

# Show VM's network config and test connectivity
[no-exit-message]
debug-vm vm_id:
    #!/usr/bin/env bash
    echo "=== VM Network Debug ==="
    echo "Checking TAP interface..."
    ip link show mj-{{vm_id}} 2>/dev/null || echo "TAP not found: mj-{{vm_id}}"
    echo ""
    echo "Checking route..."
    ip route | grep "mj-{{vm_id}}" || echo "No route via mj-{{vm_id}}"

# Capture packets on a VM's TAP interface
tcpdump-vm vm_id:
    sudo tcpdump -i mj-{{vm_id}} -n

# Clean up orphaned TAP interfaces
cleanup-taps:
    #!/usr/bin/env bash
    echo "Cleaning up orphaned TAP interfaces..."
    for tap in $(ip link show | grep -oP 'mj-\w+' | sort -u); do
        echo "Removing $tap"
        sudo ip link del "$tap" 2>/dev/null || true
    done
    echo "✓ Cleanup complete"

# ============================================================================
# Remote Debug (via TCP on localhost:9999)
# ============================================================================

# Spawn a new VM via debug server
vm-spawn:
    echo '{"cmd":"spawn"}' | nc -q1 localhost 9999 | jq .

# List all running VMs
vm-list:
    echo '{"cmd":"list"}' | nc -q1 localhost 9999 | jq .

# Execute command in a VM: just vm-exec <vm_id> <command>
vm-exec vm_id cmd:
    echo '{"cmd":"exec","vm_id":"{{vm_id}}","command":"{{cmd}}"}' | nc -q1 localhost 9999 | jq .

# Stop a VM: just vm-stop <vm_id>
vm-stop vm_id:
    echo '{"cmd":"stop","vm_id":"{{vm_id}}"}' | nc -q1 localhost 9999 | jq .

# Wait for shell to be ready: just vm-await-shell <vm_id> [timeout_ms]
vm-await-shell vm_id timeout="30000":
    echo '{"cmd":"await_shell","vm_id":"{{vm_id}}","timeout":{{timeout}}}' | nc -q1 localhost 9999 | jq .

# Get VM status
vm-status vm_id:
    echo '{"cmd":"status","vm_id":"{{vm_id}}"}' | nc -q1 localhost 9999 | jq .
