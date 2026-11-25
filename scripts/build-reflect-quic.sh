#!/usr/bin/env bash
# Build the unikernel helpers into priv/: reflect-quic-client (the host's QUIC
# client, native/reflect_quic/host.zig) and reflect-entity (entity names,
# native/reflect_quic/entity-tool.zig). Zig 0.16.0: host.zig uses its
# std.process.Init API. Run from anywhere; ZIG overrides the compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -n "${ZIG:-}" ]]; then
    zig=("$ZIG")
elif command -v zig >/dev/null && [[ "$(zig version)" == 0.16.0 ]]; then
    zig=(zig)
else
    zig=(mise exec zig@0.16.0 -- zig)
fi
version="$("${zig[@]}" version)"
[[ "$version" == 0.16.0 ]] || { echo "build-reflect-quic: Zig 0.16.0 is needed, found $version" >&2; exit 1; }
cache="${REFLECT_ZIG_CACHE:-$ROOT/_build/zig-cache}"
mkdir -p priv "$cache"
build() {
    local src="$1" out="$2"
    "${zig[@]}" build-exe "$src" -lc -O ReleaseFast \
        --cache-dir "$cache" --global-cache-dir "$cache/global" \
        -femit-bin="priv/$out.tmp"
    mv -f "priv/$out.tmp" "priv/$out"
}
build native/reflect_quic/host.zig reflect-quic-client
build native/reflect_quic/entity-tool.zig reflect-entity
echo "build-reflect-quic: priv/reflect-quic-client priv/reflect-entity (zig $version)"
