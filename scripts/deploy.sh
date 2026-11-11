#!/usr/bin/env bash
# Build a complete versioned tree, then activate it through /opt/mjolnir.
# --gateway alone updates only the gateway; --full includes the controller.
# --app-only updates the controller/runtime/dependencies without host sidecars.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
remote() { ssh -o BatchMode=yes "$HOST" "set -e; $1"; }
ACTIVE_CODE=/opt/mjolnir
RELEASES=/opt/mjolnir-releases
HOST=""
BUILD_AGENT=false
BUILD_ROOTFS=false
BUILD_GATEWAY=false
BUILD_RUNNER=false
AGENT_IROH=true
FULL_DEPLOY=false
APP_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --agent) BUILD_AGENT=true ;;
        --no-iroh) AGENT_IROH=false ;;
        --rootfs) BUILD_ROOTFS=true ;;
        --gateway) BUILD_GATEWAY=true ;;
        --runner) BUILD_RUNNER=true ;;
        --full) FULL_DEPLOY=true ;;
        --app-only) APP_ONLY=true ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *) HOST="$arg" ;;
    esac
done
HOST="${HOST:-${MJOLNIR_HOST:-}}"
[[ -n "$HOST" ]] || { echo "Usage: $0 user@host [--app-only | --gateway [--full]] [--agent] [--rootfs] [--runner]" >&2; exit 1; }
[[ "$HOST" == *@* ]] || HOST="root@$HOST"
if $APP_ONLY && { $BUILD_AGENT || $BUILD_ROOTFS || $BUILD_GATEWAY || $BUILD_RUNNER; }; then
    echo '--app-only cannot be combined with sidecar/guest build options' >&2; exit 1
fi
BUILD_ELIXIR=true
if $BUILD_GATEWAY && ! $FULL_DEPLOY; then
    BUILD_ELIXIR=false
    if $BUILD_AGENT || $BUILD_ROOTFS || $BUILD_RUNNER; then
        echo 'Use --full when combining --gateway with other build options' >&2; exit 1
    fi
fi

# Refuse the old layout before rsync can overwrite any running files.
remote "test -L $ACTIVE_CODE && test -d $ACTIVE_CODE" || {
    echo 'Migrate the existing installation to the versioned-release symlink first.' >&2; exit 1;
}
REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD)"
RELEASE_NAME="$REVISION-$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_CODE="$RELEASES/$RELEASE_NAME"
# Send the current staging helper, not a possibly old installed version.
remote "python3 - stage '$RELEASE_NAME'" < "$SCRIPT_DIR/release_control.py"
# Each destination is new. Never rsync through the active symlink. Receiver
# caches/helpers seeded by stage are protected; removed source files disappear.
rsync -az --delete --filter=':- .gitignore' --exclude='.git' --exclude='.env' \
    --exclude='.beads' --exclude='.beads.gate.lock' \
    --filter='P /bin/***' --filter='P /_build/***' --filter='P /deps/***' \
    --filter='P /native/**/target/***' --filter='P /native/target/***' \
    "$PROJECT_ROOT/" "$HOST:$REMOTE_CODE/"
remote "printf '%s\\n' '$REVISION' > '$REMOTE_CODE/.source-revision'"
# Trust the staged tool pins explicitly; use mise exec in noninteractive shells.
# shellcheck disable=SC2016 # Expanded by the remote shell.
MISE_ACTIVATE='export PATH=/root/.local/bin:/root/.cargo/bin:$PATH; command -v mise >/dev/null'
remote "$MISE_ACTIVATE; cd '$REMOTE_CODE'; mise trust .mise.toml"
native_build() {
    local kind="$1" flags="${2:-}"
    remote "systemd-run --quiet --wait --pipe --collect --property=User=root --property=SetLoginEnvironment=yes --property=CPUQuota=200% --property=MemoryMax=4G --unit='mjolnir-native-$kind-$RELEASE_NAME' /bin/bash '$REMOTE_CODE/scripts/build-native.sh' '$REMOTE_CODE' '$kind' $flags"
}
if $BUILD_AGENT; then
    AGENT_FLAGS=""
    $AGENT_IROH || AGENT_FLAGS=--no-iroh
    native_build agent "$AGENT_FLAGS"
fi
if $BUILD_ROOTFS; then
    DISTRO="${ROOTFS_DISTRO:-arch}"
    [[ "$DISTRO" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo 'Invalid ROOTFS_DISTRO' >&2; exit 1; }
    remote "$MISE_ACTIVATE; cd '$REMOTE_CODE'; AGENT_BIN=native/target/x86_64-unknown-linux-musl/release/mjolnir-agent bash scripts/build-rootfs-$DISTRO.sh /var/lib/mjolnir/btrfs/@base/$DISTRO"
fi
if $BUILD_GATEWAY; then
    native_build gateway
    remote "python3 -c 'import tomllib; tomllib.load(open(\"/etc/mjolnir/gateway.toml\", \"rb\"))'"
fi
if $BUILD_ELIXIR; then
    remote "systemd-run --quiet --wait --pipe --collect --property=User=root --property=SetLoginEnvironment=yes --property=CPUQuota=200% --property=MemoryMax=4G --unit='mjolnir-build-$RELEASE_NAME' /bin/bash '$REMOTE_CODE/scripts/build-release.sh' '$REMOTE_CODE' '$RELEASE_NAME'"
    if ! $APP_ONLY; then
        # Finish native compilation before changing the running controller.
        native_build blob
        native_build aie
    fi
    # Remote systemd owns activation so an SSH disconnect cannot abandon rollback.
    remote "systemd-run --quiet --wait --pipe --collect --unit='mjolnir-release-$RELEASE_NAME' /bin/bash '$REMOTE_CODE/scripts/cutover-release.sh' '$REMOTE_CODE'"
    if ! $APP_ONLY; then
        remote "bash $ACTIVE_CODE/scripts/ensure-host-modules.sh; bash $ACTIVE_CODE/scripts/ensure-host-nat.sh --install-unit; bash $ACTIVE_CODE/scripts/ensure-host-api-addr.sh --install-unit"
        remote "cd $ACTIVE_CODE; bash scripts/install-blob-door.sh --install-only; bash scripts/install-redis.sh; bash scripts/install-aie-sidecar.sh --install-only"
        remote "cp $ACTIVE_CODE/systemd/mjolnir-cert-renew.service $ACTIVE_CODE/systemd/mjolnir-cert-renew.timer /etc/systemd/system/; systemctl daemon-reload; systemctl enable --now mjolnir-cert-renew.timer"
    fi
fi
if $BUILD_GATEWAY; then
    remote "install -m755 '$REMOTE_CODE/native/target/release/mjolnir-gateway' /usr/local/bin/mjolnir-gateway; cp '$REMOTE_CODE/systemd/mjolnir-gateway.service' /etc/systemd/system/; systemctl daemon-reload; systemctl restart mjolnir-gateway; systemctl is-active --quiet mjolnir-gateway"
fi
if $BUILD_RUNNER; then
    remote 'set -e; if test ! -d /opt/forgejo-runner-build/.git; then git clone -b mjolnir http://10.255.255.1:3000/identikey/forgejo-runner.git /opt/forgejo-runner-build; else git -C /opt/forgejo-runner-build fetch origin; git -C /opt/forgejo-runner-build checkout mjolnir; git -C /opt/forgejo-runner-build reset --hard origin/mjolnir; fi; cd /opt/forgejo-runner-build; go build -o /usr/local/bin/forgejo-runner-mjolnir .; systemctl restart forgejo-runner; systemctl is-active --quiet forgejo-runner'
fi
echo "Deploy complete. Active controller: $ACTIVE_CODE; staged tree: $REMOTE_CODE"
