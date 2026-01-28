#!/bin/bash
set -e

# Wrapper to start Firecracker with serial console exposed on a Unix socket
# Usage: firecracker-console.sh <serial_sock> <api_sock> <vm_id> [firecracker_bin]

SERIAL_SOCK="$1"
API_SOCK="$2"
VM_ID="$3"
FC_BIN="${4:-/usr/local/bin/firecracker}"

# Remove stale sockets
rm -f "$SERIAL_SOCK"

# Create a pseudo-terminal and link it to a known path
PTY_LINK="/tmp/mjolnir-pty-${VM_ID}"

# Start socat to create a PTY pair:
# - One end ($PTY_LINK) will be used by Firecracker
# - The other end relays to the Unix socket for screen to attach
socat \
    "PTY,raw,echo=0,link=${PTY_LINK}" \
    "UNIX-LISTEN:${SERIAL_SOCK},fork,mode=666" &
SOCAT_PID=$!

# Give socat time to create the PTY
sleep 0.3

# Verify PTY was created
if [[ ! -e "$PTY_LINK" ]]; then
    echo "Failed to create PTY at $PTY_LINK" >&2
    kill $SOCAT_PID 2>/dev/null
    exit 1
fi

# Cleanup function
cleanup() {
    kill $SOCAT_PID 2>/dev/null || true
    rm -f "$PTY_LINK"
}
trap cleanup EXIT

# Start Firecracker with PTY as stdin/stdout (serial console)
exec "$FC_BIN" \
    --api-sock "$API_SOCK" \
    --id "$VM_ID" \
    --level Warning \
    < "$PTY_LINK" > "$PTY_LINK" 2>&1
