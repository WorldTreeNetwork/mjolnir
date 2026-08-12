#!/bin/bash
set -euo pipefail

# Deploy Mjolnir to a remote server.
#
# Usage:
#   ./scripts/deploy.sh <host>                 # rsync + build release + restart service
#   ./scripts/deploy.sh <host> --agent         # also rebuild guest agent (Iroh P2P on by default)
#   ./scripts/deploy.sh <host> --agent --no-iroh # rebuild guest agent without Iroh (smaller binary)
#   ./scripts/deploy.sh <host> --rootfs        # rebuild rootfs only (distro via ROOTFS_DISTRO, default: arch)
#   ./scripts/deploy.sh <host> --gateway       # GATEWAY-ONLY: build+install+restart mjolnir-gateway.
#                                               # Does NOT run `mix release` or restart the mjolnir
#                                               # service (that bounces every running VM), so this is
#                                               # the safe way to ship a gateway-only change.
#   ./scripts/deploy.sh <host> --gateway --full # gateway AND the full Elixir release + restart
#   ./scripts/deploy.sh                       # uses MJOLNIR_HOST or prompts
#
# Examples:
#   ./scripts/deploy.sh root@45.76.77.97
#   ./scripts/deploy.sh root@45.76.77.97 --agent
#   ./scripts/deploy.sh root@45.76.77.97 --rootfs
#   ./scripts/deploy.sh root@45.76.77.97 --gateway
#   ./scripts/deploy.sh root@45.76.77.97 --gateway --full
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
BUILD_RUNNER=false
AGENT_IROH=true
FULL_DEPLOY=false

for arg in "$@"; do
    case "$arg" in
        --agent) BUILD_AGENT=true ;;
        --no-iroh) AGENT_IROH=false ;;
        --rootfs) BUILD_ROOTFS=true ;;
        --gateway) BUILD_GATEWAY=true ;;
        --runner) BUILD_RUNNER=true ;;
        --full) FULL_DEPLOY=true ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *) HOST="$arg" ;;
    esac
done

# --gateway alone is gateway-only: it must NOT trigger a `mix release` +
# `systemctl restart mjolnir` (that bounces every running VM via the
# Cleanup-kills-VMs -> Reconcile-resumes-from-StateStore cycle). Pass --full
# alongside --gateway to explicitly request both. Without --gateway, the
# Elixir release/restart always runs (preserves plain `deploy.sh <host>`).
if $BUILD_GATEWAY && ! $FULL_DEPLOY; then
    BUILD_ELIXIR=false
else
    BUILD_ELIXIR=true
fi

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

# --- Preflight check for gateway config (TOML preferred, env fallback) ---
check_gateway_env() {
    local host="$1"
    local remote_code="$2"

    # Helper: color output if terminal supports it
    local yellow='' red='' green='' reset=''
    if [ -t 1 ]; then
        yellow='\e[33m'
        red='\e[31m'
        green='\e[32m'
        reset='\e[0m'
    fi

    # If /etc/mjolnir/gateway.toml exists, TOML is authoritative and env is
    # ignored at startup (spec Decision 10). Skip the env preflight.
    if ssh "$host" "[ -f /etc/mjolnir/gateway.toml ]" 2>/dev/null; then
        printf "\n=== Gateway Config Preflight (TOML mode) ===\n"
        printf "${green}/etc/mjolnir/gateway.toml present — TOML is authoritative.${reset}\n"
        printf "${yellow}Note: /etc/mjolnir/gateway.env is ignored while TOML is present.${reset}\n"
        # Lightweight parseability check; the gateway does full validation at startup.
        # Python3 tomllib is available on recent distros (3.11+).
        if ssh "$host" "python3 -c 'import tomllib; tomllib.loads(open(\"/etc/mjolnir/gateway.toml\").read())'" 2>/dev/null; then
            printf "${green}TOML parses cleanly.${reset}\n"
        else
            printf "${red}WARN: /etc/mjolnir/gateway.toml failed to parse — gateway will refuse to start.${reset}\n"
            printf "${red}Check gateway logs after deploy: journalctl -u mjolnir-gateway${reset}\n"
        fi
        printf "=== End Preflight Check ===\n\n"
        return 0
    fi

    # Check if /etc/mjolnir/gateway.env exists on the host
    if ! ssh "$host" "[ -f /etc/mjolnir/gateway.env ]" 2>/dev/null; then
        printf "${yellow}=== WARN: Gateway config not found ===${reset}\n"
        printf "${yellow}Neither /etc/mjolnir/gateway.toml nor /etc/mjolnir/gateway.env exists.${reset}\n"
        printf "${yellow}To set up the gateway config, pick one:${reset}\n"
        printf "${yellow}  TOML (preferred for multi-apex / local-routes):${reset}\n"
        printf "${yellow}    cp $remote_code/systemd/gateway.toml.example /etc/mjolnir/gateway.toml${reset}\n"
        printf "${yellow}  Env (legacy single-apex):${reset}\n"
        printf "${yellow}    cp $remote_code/systemd/gateway.env.example /etc/mjolnir/gateway.env${reset}\n"
        printf "${yellow}Then edit the file and re-run the deploy script.${reset}\n"
        printf "${yellow}Proceeding with deploy (gateway service may not start cleanly).${reset}\n"
        return 0
    fi

    printf "\n=== Gateway Environment Preflight Check (env mode) ===\n"

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

# --- Build Forgejo runner with Mjolnir VM backend (optional) ---
if $BUILD_RUNNER; then
    echo ""
    echo "--- Building Forgejo runner (Mjolnir VM backend) ---"

    RUNNER_REPO="http://10.255.255.1:3000/identikey/forgejo-runner.git"
    RUNNER_BRANCH="mjolnir"

    # Clone or update the fork
    ssh "$HOST" "if [ ! -d /opt/forgejo-runner-build/.git ]; then \
        git clone -b $RUNNER_BRANCH $RUNNER_REPO /opt/forgejo-runner-build; \
    else \
        cd /opt/forgejo-runner-build && git fetch origin && git checkout $RUNNER_BRANCH && git reset --hard origin/$RUNNER_BRANCH; \
    fi"

    # Build
    ssh "$HOST" "cd /opt/forgejo-runner-build && go build -o /usr/local/bin/forgejo-runner-mjolnir ."

    # Install systemd service
    ssh "$HOST" "cp $REMOTE_CODE/systemd/forgejo-runner.service /etc/systemd/system/forgejo-runner.service && systemctl daemon-reload"
fi

# --- Build Elixir release (skipped in gateway-only mode: --gateway without --full) ---
if $BUILD_ELIXIR; then
    echo ""
    echo "--- Building Elixir release ---"
    ssh "$HOST" "$MISE_ACTIVATE && cd $REMOTE_CODE && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile && MIX_ENV=prod mix release mjolnir --overwrite"
else
    echo ""
    echo "--- Skipping Elixir release build (gateway-only deploy; pass --full to also rebuild it) ---"
fi

# --- Update gateway systemd service ---
ssh "$HOST" "if [ -f $REMOTE_CODE/systemd/mjolnir-gateway.service ]; then cp $REMOTE_CODE/systemd/mjolnir-gateway.service /etc/systemd/system/mjolnir-gateway.service && systemctl daemon-reload; fi"

# --- Preflight gateway env check (if gateway is/will be enabled) ---
if $BUILD_GATEWAY || ssh "$HOST" "systemctl is-enabled mjolnir-gateway 2>/dev/null" | grep -q enabled; then
    check_gateway_env "$HOST" "$REMOTE_CODE"
fi

# --- Restart service (skipped in gateway-only mode: --gateway without --full) ---
if $BUILD_ELIXIR; then
    echo ""
    echo "--- Restarting mjolnir service ---"
    ssh "$HOST" "systemctl restart mjolnir && sleep 2 && systemctl status mjolnir --no-pager"
else
    echo ""
    echo "--- Skipping mjolnir service restart (gateway-only deploy; pass --full to also restart it) ---"
fi

# --- Restart gateway if installed ---
if $BUILD_GATEWAY || ssh "$HOST" "systemctl is-enabled mjolnir-gateway 2>/dev/null" | grep -q enabled; then
    echo ""
    echo "--- Restarting gateway service ---"
    ssh "$HOST" "systemctl restart mjolnir-gateway && sleep 1 && systemctl status mjolnir-gateway --no-pager"
fi

# --- Restart runner if installed ---
if $BUILD_RUNNER || ssh "$HOST" "systemctl is-enabled forgejo-runner 2>/dev/null" | grep -q enabled; then
    echo ""
    echo "--- Restarting forgejo-runner service ---"
    ssh "$HOST" "systemctl restart forgejo-runner && sleep 1 && systemctl status forgejo-runner --no-pager"
fi

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Logs:         ssh $HOST journalctl -u mjolnir -f"
echo "Gateway logs: ssh $HOST journalctl -u mjolnir-gateway -f"
echo "Runner logs:  ssh $HOST journalctl -u forgejo-runner -f"
echo "Remote shell: ssh $HOST /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote"
