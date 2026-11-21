#!/usr/bin/env bash
# Compile native artifacts in a staged tree; never starts the controller.
set -euo pipefail
ROOT="${1:?release source root required}"
KIND="${2:?agent, blob, aie, gateway or relay required}"
shift 2
export PATH=/root/.local/bin:/root/.cargo/bin:$PATH
# Limit concurrent rustc/linker memory as well as the containing systemd unit.
export CARGO_BUILD_JOBS=1
cd "$ROOT"
case "$KIND" in
    agent) exec mise exec -- bash scripts/build-guest-agent.sh "$@" ;;
    blob) cd native; exec mise exec -- cargo build -p mjolnir-blob-door --release --locked ;;
    aie) cd native; exec mise exec -- cargo build -p mjolnir-aie-sidecar --release --locked ;;
    gateway) cd native/mjolnir_gateway; exec mise exec -- cargo build --release --locked ;;
    relay)
        # Keep the object cache across release directories. Each deploy stages a
        # fresh tree, and a cold aws-lc build is several minutes.
        export CARGO_TARGET_DIR=/var/tmp/mjolnir-relay-cargo
        cd native/mjolnir_relay
        mise exec -- cargo build --release --locked
        mkdir -p "$ROOT/native/mjolnir_relay/target/release"
        cp -f "$CARGO_TARGET_DIR/release/mjolnir-relay" "$ROOT/native/mjolnir_relay/target/release/mjolnir-relay"
        ;;
    *) echo "Unknown native build: $KIND" >&2; exit 1 ;;
esac
