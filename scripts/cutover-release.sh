#!/usr/bin/env bash
# Activate a complete versioned release, with guest continuity and rollback.
set -euo pipefail
ROOT="${1:-${MJOLNIR_CODE:-}}"
[[ -n "$ROOT" ]] || { echo 'Usage: cutover-release.sh /opt/mjolnir-releases/<release>' >&2; exit 1; }
exec python3 "$(dirname "$0")/release_control.py" activate "$ROOT"
