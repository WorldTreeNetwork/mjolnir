#!/bin/bash
set -euo pipefail

# Deploy Mjolnir to a remote server.
#
# Usage:
#   ./scripts/deploy.sh <host>                # rsync + rebuild elixir server
#   ./scripts/deploy.sh <host> --agent        # also rebuild guest agent + rootfs
#   ./scripts/deploy.sh <host> --rootfs       # rebuild rootfs only (no agent recompile)
#   ./scripts/deploy.sh                       # uses MJOLNIR_HOST or prompts
#
# Examples:
#   ./scripts/deploy.sh root@45.76.77.97
#   ./scripts/deploy.sh root@45.76.77.97 --agent
#   ./scripts/deploy.sh root@45.76.77.97 --rootfs
#   MJOLNIR_HOST=root@mybox ./scripts/deploy.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE_CODE="/opt/mjolnir"
REMOTE_BTRFS="/var/lib/mjolnir/btrfs"

# Parse args
HOST=""
BUILD_AGENT=false
BUILD_ROOTFS=false

for arg in "$@"; do
    case "$arg" in
        --agent) BUILD_AGENT=true ;;
        --rootfs) BUILD_ROOTFS=true ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *) HOST="$arg" ;;
    esac
done

HOST="${HOST:-${MJOLNIR_HOST:-}}"
if [[ -z "$HOST" ]]; then
    echo "Usage: $0 <user@host> [--agent]"
    exit 1
fi

# Ensure host has user@ prefix
if [[ "$HOST" != *@* ]]; then
    HOST="root@$HOST"
fi

MISE_ACTIVATE='eval "$($HOME/.local/bin/mise activate bash)"'

echo "=== Deploying to $HOST ==="

# --- Rsync ---
echo ""
echo "--- Syncing code ---"
rsync -avz --delete \
    --exclude='_build' \
    --exclude='deps' \
    --exclude='.git' \
    --exclude='native/target' \
    --exclude='native/*/target' \
    --exclude='.DS_Store' \
    --exclude='.claude' \
    "$PROJECT_ROOT/" "$HOST:$REMOTE_CODE/"

# --- Rebuild Elixir ---
echo ""
echo "--- Rebuilding Elixir server ---"
ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && mix deps.get --only prod && mix compile"

# --- Restart reminder ---
echo ""
echo "Restart the server in your tmux session (iex -S mix)"

# --- Guest agent + rootfs (optional) ---
if $BUILD_AGENT; then
    echo ""
    echo "--- Building guest agent (musl static binary) ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && ./scripts/build-guest-agent.sh"
    BUILD_ROOTFS=true
fi

if $BUILD_ROOTFS; then
    echo ""
    echo "--- Rebuilding rootfs ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && sudo ./scripts/build-rootfs.sh $REMOTE_BTRFS/@base/ubuntu-24.04.ext4"
fi

echo ""
echo "=== Deploy complete ==="
