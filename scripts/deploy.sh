#!/bin/bash
set -euo pipefail

# Deploy Mjolnir to a remote server.
#
# Usage:
#   ./scripts/deploy.sh <host>                # rsync + build release + restart service
#   ./scripts/deploy.sh <host> --agent        # also rebuild guest agent (vsock-only)
#   ./scripts/deploy.sh <host> --agent --iroh # rebuild guest agent with Iroh P2P
#   ./scripts/deploy.sh <host> --rootfs       # rebuild rootfs only (distro via ROOTFS_DISTRO, default: arch)
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
BUILD_GATEWAY=false
AGENT_IROH=false

for arg in "$@"; do
    case "$arg" in
        --agent) BUILD_AGENT=true ;;
        --iroh) AGENT_IROH=true ;;
        --rootfs) BUILD_ROOTFS=true ;;
        --gateway) BUILD_GATEWAY=true ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *) HOST="$arg" ;;
    esac
done

HOST="${HOST:-${MJOLNIR_HOST:-}}"
if [[ -z "$HOST" ]]; then
    echo "Usage: $0 <user@host> [--agent] [--rootfs]"
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
    --filter=':- .gitignore' \
    --exclude='.git' \
    "$PROJECT_ROOT/" "$HOST:$REMOTE_CODE/"

# --- Update systemd service file ---
echo ""
echo "--- Updating systemd service ---"
ssh "$HOST" "cp $REMOTE_CODE/systemd/mjolnir.service /etc/systemd/system/mjolnir.service && systemctl daemon-reload"

# --- Guest agent + rootfs (optional, before release build) ---
if $BUILD_AGENT; then
    AGENT_FLAGS=""
    if $AGENT_IROH; then
        AGENT_FLAGS="--iroh"
    fi
    echo ""
    echo "--- Building guest agent (musl static binary) ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && ./scripts/build-guest-agent.sh $AGENT_FLAGS"
fi

if $BUILD_ROOTFS; then
    DISTRO="${ROOTFS_DISTRO:-arch}"
    echo ""
    echo "--- Rebuilding rootfs (distro: $DISTRO) ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && AGENT_BIN=native/target/x86_64-unknown-linux-musl/release/mjolnir-agent sudo bash scripts/build-rootfs-${DISTRO}.sh $REMOTE_BTRFS/@base/${DISTRO}"
fi

# --- Build gateway (optional) ---
if $BUILD_GATEWAY; then
    echo ""
    echo "--- Building gateway ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE/native/mjolnir_gateway && cargo build --release"
    ssh "$HOST" "cp $REMOTE_CODE/native/target/release/mjolnir-gateway /usr/local/bin/"
fi

# --- Build Elixir release ---
echo ""
echo "--- Building Elixir release ---"
ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile && MIX_ENV=prod mix release mjolnir --overwrite"

# --- Update gateway systemd service ---
ssh "$HOST" "if [ -f $REMOTE_CODE/systemd/mjolnir-gateway.service ]; then cp $REMOTE_CODE/systemd/mjolnir-gateway.service /etc/systemd/system/mjolnir-gateway.service && systemctl daemon-reload; fi"

# --- Restart service ---
echo ""
echo "--- Restarting mjolnir service ---"
ssh "$HOST" "systemctl restart mjolnir && sleep 2 && systemctl status mjolnir --no-pager"

# --- Restart gateway if installed ---
if $BUILD_GATEWAY || ssh "$HOST" "systemctl is-enabled mjolnir-gateway 2>/dev/null" | grep -q enabled; then
    echo ""
    echo "--- Restarting gateway service ---"
    ssh "$HOST" "systemctl restart mjolnir-gateway && sleep 1 && systemctl status mjolnir-gateway --no-pager"
fi

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Logs:         ssh $HOST journalctl -u mjolnir -f"
echo "Gateway logs: ssh $HOST journalctl -u mjolnir-gateway -f"
echo "Remote shell: ssh $HOST /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote"
