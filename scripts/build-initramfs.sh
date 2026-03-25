#!/bin/bash
set -euo pipefail

# Mjolnir initramfs build script
# Produces a reproducible gzip-compressed newc cpio archive at boot-image/initramfs.img.
# Must run on Linux (requires GNU cpio). Run via: ssh server "cd /opt/mjolnir && scripts/build-initramfs.sh"
#
# Prerequisites:
#   - native/target/x86_64-unknown-linux-musl/release/mjolnir-boot-agent (built by build-boot-agent Justfile target)
#   - GNU cpio, gzip, sha256sum, curl

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="$PROJECT_ROOT/boot-image"
CACHE_DIR="$OUTPUT_DIR/.cache"
STAGING_DIR="$OUTPUT_DIR/.staging"
OUTPUT_IMG="$OUTPUT_DIR/initramfs.img"
BOOT_AGENT_BIN="$PROJECT_ROOT/native/target/x86_64-unknown-linux-musl/release/mjolnir-boot-agent"
INIT_SCRIPT="$SCRIPT_DIR/initramfs-init.sh"

# Busybox static x86_64 binary
# Primary: use system busybox if available, statically linked, and SHA256 matches
# Fallback: download from busybox.net (pinned older version — 1.36.1 not available there)
BUSYBOX_SYSTEM="/usr/bin/busybox"
BUSYBOX_CACHE="$CACHE_DIR/busybox"

# Download fallback: busybox.net only has up to 1.35.0 for x86_64-linux-musl
BUSYBOX_DOWNLOAD_VERSION="1.35.0"
BUSYBOX_DOWNLOAD_URL="https://busybox.net/downloads/binaries/${BUSYBOX_DOWNLOAD_VERSION}-x86_64-linux-musl/busybox"
BUSYBOX_DOWNLOAD_SHA256="6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348"

# System busybox: Ubuntu busybox-static 1:1.36.1-6ubuntu3.1 (apt install busybox-static)
BUSYBOX_SYSTEM_SHA256="dbac288c29ba568459550a2da9e7ae0ded6b1fc728ee9fad3044c44e62d6ac14"

MAX_SIZE_BYTES=$((10 * 1024 * 1024))  # 10MB hard limit

echo "=== Building Mjolnir initramfs ==="

# --- Validate prerequisites ---
if [ ! -f "$BOOT_AGENT_BIN" ]; then
    echo "ERROR: Boot agent binary not found: $BOOT_AGENT_BIN"
    echo "Run 'just build-boot-agent' first."
    exit 1
fi

if [ ! -f "$INIT_SCRIPT" ]; then
    echo "ERROR: Init script not found: $INIT_SCRIPT"
    exit 1
fi

# --- Setup directories ---
mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/bin"

# --- Obtain and verify busybox ---
if [ ! -f "$BUSYBOX_CACHE" ]; then
    if [ -f "$BUSYBOX_SYSTEM" ] && file "$BUSYBOX_SYSTEM" | grep -q "statically linked"; then
        echo "--- Trying system busybox ---"
        ACTUAL_SHA256=$(sha256sum "$BUSYBOX_SYSTEM" | awk '{print $1}')
        if [ "$ACTUAL_SHA256" = "$BUSYBOX_SYSTEM_SHA256" ]; then
            echo "OK: system busybox SHA256 matches pinned value"
            cp "$BUSYBOX_SYSTEM" "$BUSYBOX_CACHE"
        else
            echo "WARN: system busybox SHA256 mismatch (got $ACTUAL_SHA256)"
            echo "      expected $BUSYBOX_SYSTEM_SHA256"
            echo "      Falling back to download..."
        fi
    fi
fi

if [ ! -f "$BUSYBOX_CACHE" ]; then
    echo "--- Downloading busybox ${BUSYBOX_DOWNLOAD_VERSION} from busybox.net ---"
    curl -fsSL --connect-timeout 30 -o "$BUSYBOX_CACHE.tmp" "$BUSYBOX_DOWNLOAD_URL"
    ACTUAL_SHA256=$(sha256sum "$BUSYBOX_CACHE.tmp" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$BUSYBOX_DOWNLOAD_SHA256" ]; then
        echo "ERROR: downloaded busybox SHA256 mismatch"
        echo "  expected: $BUSYBOX_DOWNLOAD_SHA256"
        echo "  got:      $ACTUAL_SHA256"
        rm -f "$BUSYBOX_CACHE.tmp"
        exit 1
    fi
    echo "OK: downloaded busybox SHA256 verified"
    mv "$BUSYBOX_CACHE.tmp" "$BUSYBOX_CACHE"
fi

echo "--- Verifying busybox is statically linked ---"
if ! file "$BUSYBOX_CACHE" | grep -q "statically linked"; then
    echo "ERROR: busybox is not statically linked — cannot use in initramfs"
    rm -f "$BUSYBOX_CACHE"
    exit 1
fi
echo "OK: busybox is statically linked"

# --- Validate required busybox applets ---
chmod +x "$BUSYBOX_CACHE"
MISSING=""
for applet in sh mount mkdir switch_root sleep killall; do
    if ! "$BUSYBOX_CACHE" --list | grep -q "^${applet}$"; then
        MISSING="$MISSING $applet"
    fi
done
if [ -n "$MISSING" ]; then
    echo "ERROR: busybox missing required applets:$MISSING"
    exit 1
fi
echo "OK: required applets present (sh mount mkdir switch_root sleep killall)"

# --- Populate staging directory ---
echo "--- Populating staging directory ---"

# Copy busybox
cp "$BUSYBOX_CACHE" "$STAGING_DIR/bin/busybox"
chmod 755 "$STAGING_DIR/bin/busybox"

# Create busybox symlinks
for applet in sh mount mkdir switch_root sleep killall; do
    ln -sf busybox "$STAGING_DIR/bin/$applet"
done

# Copy boot agent
cp "$BOOT_AGENT_BIN" "$STAGING_DIR/bin/mjolnir-boot-agent"
chmod 755 "$STAGING_DIR/bin/mjolnir-boot-agent"

# Copy init script as /init
cp "$INIT_SCRIPT" "$STAGING_DIR/init"
chmod 755 "$STAGING_DIR/init"

echo "Staging contents:"
find "$STAGING_DIR" | sort | sed "s|$STAGING_DIR||"

# --- Zero all timestamps for reproducibility ---
# GNU cpio does NOT honor SOURCE_DATE_EPOCH — it records actual file mtimes.
# Force all files/dirs to epoch 0 so the archive is byte-identical across runs.
find "$STAGING_DIR" -exec touch -h -d @0 {} +

# --- Build cpio archive ---
echo "--- Building cpio archive ---"

# find . | sort: deterministic ordering
# cpio --reproducible: zero inode/device numbers
# -o -H newc: output in newc (new ASCII) format
# --owner=0:0: strip host UID/GID, use root:root
# gzip --no-name: omit filename/timestamp from gzip header
(
    cd "$STAGING_DIR"
    find . | sort | \
        cpio --reproducible -o -H newc --owner=0:0 | \
        gzip --no-name > "$OUTPUT_IMG"
)

# --- Size check ---
ACTUAL_SIZE=$(stat -c%s "$OUTPUT_IMG")
echo "Archive size: $((ACTUAL_SIZE / 1024))KB"

if [ "$ACTUAL_SIZE" -gt "$MAX_SIZE_BYTES" ]; then
    echo "ERROR: initramfs.img exceeds 10MB limit (${ACTUAL_SIZE} bytes)"
    rm -f "$OUTPUT_IMG"
    exit 1
fi

# --- Done ---
SHA256=$(sha256sum "$OUTPUT_IMG" | awk '{print $1}')
echo ""
echo "=== Build complete ==="
echo "Output: $OUTPUT_IMG"
echo "Size:   $((ACTUAL_SIZE / 1024))KB"
echo "SHA256: $SHA256"
