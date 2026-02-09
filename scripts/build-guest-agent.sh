#!/bin/bash
set -euo pipefail

# Build the guest agent for musl (static binary that works in minimal rootfs)
# Run from project root

cd "$(dirname "$0")/../native/mjolnir_guest_agent"

echo "=== Building Mjolnir Guest Agent ==="

# Ensure musl target is installed
if ! rustup target list --installed | grep -q x86_64-unknown-linux-musl; then
    echo "Installing musl target..."
    rustup target add x86_64-unknown-linux-musl
fi

# Build static binary
echo "Building release binary..."
cargo build --release --target x86_64-unknown-linux-musl

BINARY="target/x86_64-unknown-linux-musl/release/mjolnir-agent"

if [[ -f "$BINARY" ]]; then
    echo ""
    echo "=== Build Complete ==="
    echo "Binary: $(pwd)/$BINARY"
    echo "Size: $(du -h "$BINARY" | cut -f1)"
    echo ""
    echo "To install in rootfs, run bootstrap-host.sh or copy manually"
else
    echo "ERROR: Build failed"
    exit 1
fi
