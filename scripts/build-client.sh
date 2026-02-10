#!/bin/bash
set -euo pipefail

# Build the mjolnir client for the current host platform
# Run from project root

cd "$(dirname "$0")/../native"

echo "=== Building Mjolnir Client ==="

# Build release binary from workspace
echo "Building release binary for $(rustc -vV | grep host | cut -d' ' -f2)..."
cargo build --release -p mjolnir-client

BINARY="target/release/mjolnir"

if [[ -f "$BINARY" ]]; then
    echo ""
    echo "=== Build Complete ==="
    echo "Binary: $(pwd)/$BINARY"
    echo "Size: $(du -h "$BINARY" | cut -f1)"
    echo ""
    echo "Install with: cp $(pwd)/$BINARY /usr/local/bin/mjolnir"
else
    echo "ERROR: Build failed"
    exit 1
fi
