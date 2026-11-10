#!/usr/bin/env bash
# Isolated deployment/rollback tests; never connects to production.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/test_release_control.py" "$@"
