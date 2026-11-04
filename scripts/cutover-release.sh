#!/bin/bash
# Make the newly built release the one serving health without restarting
# the mjolnir unit. A unit restart kills Port-owned hypervisors (Cleanup).
# The first boot, when the unit is inactive, starts it. An active node loads
# the new beams in place.
set -euo pipefail

ROOT="${MJOLNIR_CODE:-/opt/mjolnir}"
BIN="$ROOT/_build/prod/rel/mjolnir/bin/mjolnir"
BOOT="$ROOT/scripts/cutover_boot.exs"

if ! systemctl is-active --quiet mjolnir; then
    echo "mjolnir is not active; starting it"
    systemctl start mjolnir
    exit 0
fi

if [[ ! -x "$BIN" ]]; then
    echo "Error: $BIN is missing; not stopping mjolnir" >&2
    exit 1
fi

if [[ ! -f "$BOOT" ]]; then
    echo "Error: $BOOT is missing; not stopping mjolnir" >&2
    exit 1
fi

code=$(printf 'root = "%s"\n%s\n' "$ROOT" "$(cat "$BOOT")")
echo "--- hot cutover; mjolnir unit stays up ---"
"$BIN" rpc "$code"
echo
