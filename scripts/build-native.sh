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
        # The host's default toolchain can be older than the relay needs, and mise
        # pins RUSTUP_TOOLCHAIN, which outranks rust-toolchain.toml. Select the
        # relay's own toolchain here and leave the host default alone.
        RELAY_RUST="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
        [[ -n "$RELAY_RUST" ]] || { echo 'relay: no channel in rust-toolchain.toml' >&2; exit 1; }
        rustup toolchain install "$RELAY_RUST" --profile minimal
        # iroh-live-relay's build script runs `npm install` and `npm run build`
        # for a web client this relay never serves (it has no HTTP listener).
        # Hand it a stand-in that writes an empty bundle, so the host needs no
        # Node and no package is fetched or run as root. Goes away with the
        # dependency (mjolnir-rurh.2 follow-up).
        NPM_STUB="$(mktemp -d)"
        trap 'rm -rf "$NPM_STUB"' EXIT
        cat > "$NPM_STUB/npm" <<'STUB'
#!/usr/bin/env bash
# Stand-in for npm during the relay build. Runs in the crate's web/ directory.
set -euo pipefail
if [[ "${1:-}" == run && "${2:-}" == build ]]; then
    mkdir -p dist
    printf '<!doctype html><title>not served</title>\n' > dist/index.html
fi
STUB
        chmod 0755 "$NPM_STUB/npm"
        mise exec -- env PATH="$NPM_STUB:$PATH" RUSTUP_TOOLCHAIN="$RELAY_RUST" cargo build --release --locked
        mkdir -p "$ROOT/native/mjolnir_relay/target/release"
        cp -f "$CARGO_TARGET_DIR/release/mjolnir-relay" "$ROOT/native/mjolnir_relay/target/release/mjolnir-relay"
        ;;
    *) echo "Unknown native build: $KIND" >&2; exit 1 ;;
esac
