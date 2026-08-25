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

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Build failed"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "Binary: $(pwd)/$BINARY"
echo "Size: $(du -h "$BINARY" | cut -f1)"
echo ""

if [[ "${1:-}" == "--install" ]]; then
    if [[ -n "${MJOLNIR_INSTALL:-}" ]]; then
        INSTALL_DIR="$MJOLNIR_INSTALL"
    elif [[ -w /usr/local/bin ]]; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="$HOME/.local/bin"
    fi
    mkdir -p "$INSTALL_DIR"
    echo "Installing to ${INSTALL_DIR}..."

    cp "$BINARY" "${INSTALL_DIR}/mjolnir"
    chmod +x "${INSTALL_DIR}/mjolnir"

    # macOS kills a copied adhoc/linker-signed Mach-O with
    # SIGKILL (Code Signature Invalid). Re-sign in place so
    # ~/.local/bin/mj actually launches. The cargo target/ copy
    # is fine; only the install path trips AMFI.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        codesign --force --sign - "${INSTALL_DIR}/mjolnir"
    fi

    # Create 'mj' symlink
    LINK="${INSTALL_DIR}/mj"
    if [[ -L "$LINK" ]] || [[ -e "$LINK" ]]; then
        rm -f "$LINK"
    fi
    ln -s mjolnir "$LINK"

    if ! "${INSTALL_DIR}/mjolnir" --help >/dev/null; then
        echo "ERROR: installed binary at ${INSTALL_DIR}/mjolnir would not run"
        exit 1
    fi

    echo "Installed: ${INSTALL_DIR}/mjolnir"
    echo "Symlink:   ${INSTALL_DIR}/mj -> mjolnir"

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
        echo ""
        echo "⚠ ${INSTALL_DIR} is not in your PATH. Add it with:"
        echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    fi
else
    echo "Install with:"
    echo "  $0 --install"
    echo "  # or manually:"
    echo "  #   cp $(pwd)/$BINARY /usr/local/bin/mjolnir"
    echo "  #   ln -sf mjolnir /usr/local/bin/mj   # 'mj' shorthand"
fi
