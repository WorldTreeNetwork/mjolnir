#!/bin/bash
set -euo pipefail

# Deploy Mjolnir to a remote server.
#
# Usage:
#   ./scripts/deploy.sh <host>                 # rsync + build release + restart service
#   ./scripts/deploy.sh <host> --agent         # also rebuild guest agent (Iroh P2P on by default)
#   ./scripts/deploy.sh <host> --agent --no-iroh # rebuild guest agent without Iroh (smaller binary)
#   ./scripts/deploy.sh <host> --rootfs        # rebuild rootfs only (distro via ROOTFS_DISTRO, default: arch)
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
AGENT_IROH=true

for arg in "$@"; do
    case "$arg" in
        --agent) BUILD_AGENT=true ;;
        --no-iroh) AGENT_IROH=false ;;
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

# --- Preflight check for gateway environment config ---
check_gateway_env() {
    local host="$1"
    local remote_code="$2"

    # Helper: color output if terminal supports it
    local yellow='' red='' reset=''
    if [ -t 1 ]; then
        yellow='\e[33m'
        red='\e[31m'
        reset='\e[0m'
    fi

    # Check if /etc/mjolnir/gateway.env exists on the host
    if ! ssh "$host" "[ -f /etc/mjolnir/gateway.env ]" 2>/dev/null; then
        printf "${yellow}=== WARN: Gateway environment file not found ===${reset}\n"
        printf "${yellow}/etc/mjolnir/gateway.env does not exist on the remote host.${reset}\n"
        printf "${yellow}To set up the gateway environment:${reset}\n"
        printf "${yellow}  1. On the host, create /etc/mjolnir/ if it does not exist${reset}\n"
        printf "${yellow}  2. Copy $remote_code/systemd/gateway.env.example to /etc/mjolnir/gateway.env${reset}\n"
        printf "${yellow}  3. Edit /etc/mjolnir/gateway.env and configure as needed${reset}\n"
        printf "${yellow}  4. Re-run the deploy script${reset}\n"
        printf "${yellow}Proceeding with deploy (gateway service may not start cleanly).${reset}\n"
        return 0
    fi

    printf "\n=== Gateway Environment Preflight Check ===\n"

    # Extract example keys
    local example_keys=$(ssh "$host" "grep -E '^[A-Z_]+=.*' '$remote_code/systemd/gateway.env.example' | cut -d= -f1 | sort -u" 2>/dev/null || echo "")

    # Extract host keys
    local host_keys=$(ssh "$host" "grep -E '^[A-Z_]+=.*' /etc/mjolnir/gateway.env 2>/dev/null | cut -d= -f1 | sort -u" || echo "")

    # Find missing or empty keys
    local missing_keys=()
    while IFS= read -r key; do
        if [ -z "$key" ]; then
            continue
        fi
        # Check if key exists in host env and is non-empty
        local host_value=$(ssh "$host" "grep -E \"^${key}=\" /etc/mjolnir/gateway.env 2>/dev/null | cut -d= -f2-" || echo "")
        if [ -z "$host_value" ]; then
            missing_keys+=("$key")
        fi
    done <<< "$example_keys"

    # Report missing keys
    if [ ${#missing_keys[@]} -gt 0 ]; then
        printf "${yellow}Missing or empty keys (from example):${reset}\n"
        for key in "${missing_keys[@]}"; do
            printf "  ${yellow}${key}${reset}\n"
        done
    fi

    # Check ACME requirements if enabled
    local acme_enabled=$(ssh "$host" "grep -E '^GATEWAY_ACME=enabled' /etc/mjolnir/gateway.env 2>/dev/null" || echo "")
    if [ -n "$acme_enabled" ]; then
        printf "\n${yellow}ACME is enabled. Checking required fields...${reset}\n"

        local acme_required=("CLOUDFLARE_API_TOKEN" "GATEWAY_ACME_EMAIL" "GATEWAY_ACME_DOMAINS")
        local acme_missing=()

        for key in "${acme_required[@]}"; do
            local value=$(ssh "$host" "grep -E \"^${key}=\" /etc/mjolnir/gateway.env 2>/dev/null | cut -d= -f2-" || echo "")
            if [ -z "$value" ]; then
                acme_missing+=("$key")
            fi
        done

        if [ ${#acme_missing[@]} -gt 0 ]; then
            printf "${red}ACME enabled but missing/empty required fields:${reset}\n"
            for key in "${acme_missing[@]}"; do
                printf "  ${red}${key}${reset}\n"
            done
        else
            printf "${yellow}All ACME required fields are set.${reset}\n"
        fi
    fi

    # Report currently-set TLS/ACME values (redacted)
    printf "\n=== Current TLS/ACME Configuration ===\n"

    local tls_vars=("GATEWAY_LISTEN" "GATEWAY_TLS_LISTEN" "GATEWAY_TLS_CERT" "GATEWAY_TLS_KEY" "GATEWAY_ACME" "GATEWAY_ACME_DIRECTORY" "GATEWAY_ACME_DOMAINS" "CLOUDFLARE_API_TOKEN")

    for var in "${tls_vars[@]}"; do
        local value=$(ssh "$host" "grep -E \"^${var}=\" /etc/mjolnir/gateway.env 2>/dev/null | cut -d= -f2-" || echo "(unset)")

        if [ "$var" = "CLOUDFLARE_API_TOKEN" ] && [ "$value" != "(unset)" ] && [ -n "$value" ]; then
            value="(set)"
        fi

        printf "  %s=%s\n" "$var" "$value"
    done

    printf "=== End Preflight Check ===\n\n"
}

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
    if ! $AGENT_IROH; then
        AGENT_FLAGS="--no-iroh"
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
    ssh "$HOST" "install -m755 $REMOTE_CODE/native/target/release/mjolnir-gateway /usr/local/bin/mjolnir-gateway"
fi

# --- Build Elixir release ---
echo ""
echo "--- Building Elixir release ---"
ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile && MIX_ENV=prod mix release mjolnir --overwrite"

# --- Update gateway systemd service ---
ssh "$HOST" "if [ -f $REMOTE_CODE/systemd/mjolnir-gateway.service ]; then cp $REMOTE_CODE/systemd/mjolnir-gateway.service /etc/systemd/system/mjolnir-gateway.service && systemctl daemon-reload; fi"

# --- Preflight gateway env check (if gateway is/will be enabled) ---
if $BUILD_GATEWAY || ssh "$HOST" "systemctl is-enabled mjolnir-gateway 2>/dev/null" | grep -q enabled; then
    check_gateway_env "$HOST" "$REMOTE_CODE"
fi

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
