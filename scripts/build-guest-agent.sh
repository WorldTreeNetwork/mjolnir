#!/bin/bash
set -euo pipefail

# Build the guest agent for musl (static binary that works in minimal rootfs)
#
# Usage:
#   ./scripts/build-guest-agent.sh            # default: vsock-only (2MB, fast)
#   ./scripts/build-guest-agent.sh --iroh     # include Iroh P2P shell (23MB)
#
# Run from project root

cd "$(dirname "$0")/../native/mjolnir_guest_agent"

# Parse args
FEATURES=""
for arg in "$@"; do
    case "$arg" in
        --iroh) FEATURES="--features iroh" ;;
        *) echo "Unknown flag: $arg (use --iroh to enable Iroh P2P)"; exit 1 ;;
    esac
done

echo "=== Building Mjolnir Guest Agent ==="
if [[ -n "$FEATURES" ]]; then
    echo "Features: iroh (P2P shell enabled)"
else
    echo "Features: none (vsock-only mode)"
fi

# Ensure musl target is installed (zigbuild still needs the Rust stdlib for this target)
if ! rustup target list --installed | grep -q x86_64-unknown-linux-musl; then
    echo "Installing musl target..."
    rustup target add x86_64-unknown-linux-musl
fi

if ! cargo zigbuild --version &>/dev/null; then
    echo "Installing cargo-zigbuild..."
    cargo install cargo-zigbuild
fi

# Build static binary via zigbuild (hermetic musl, no system loader dependency)
echo "Building release binary..."
cargo zigbuild --release --target x86_64-unknown-linux-musl --bin mjolnir-agent $FEATURES

# Cargo workspace puts the binary in the workspace root's target dir
BINARY="../target/x86_64-unknown-linux-musl/release/mjolnir-agent"

if [[ -f "$BINARY" ]]; then
    echo ""
    echo "=== Build Complete ==="
    echo "Binary: $(pwd)/$BINARY"
    echo "Size: $(du -h "$BINARY" | cut -f1)"
    echo ""
    echo "To install in rootfs, run bootstrap-host-ubuntu.sh (or -arch.sh) or copy manually"
else
    echo "ERROR: Build failed"
    exit 1
fi
