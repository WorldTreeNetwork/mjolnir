#!/usr/bin/env bash
# Compile native artifacts in a staged tree; never starts the controller.
set -euo pipefail
ROOT="${1:?release source root required}"
KIND="${2:?agent, blob, aie or gateway required}"
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
    *) echo "Unknown native build: $KIND" >&2; exit 1 ;;
esac
