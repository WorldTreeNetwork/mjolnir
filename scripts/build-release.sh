#!/usr/bin/env bash
# Host build only: never starts a second application/controller.
set -euo pipefail
ROOT="${1:?release source root required}"
STAMP="${2:?release stamp required}"
cd "$ROOT"
export PATH=/root/.local/bin:/root/.cargo/bin:$PATH
export ERL_FLAGS='+S 2:2'
export MIX_ENV=prod
export MIX_HOME="${MJOLNIR_BUILD_CACHE:-/var/cache/mjolnir}/mix"
export HEX_HOME="${MJOLNIR_BUILD_CACHE:-/var/cache/mjolnir}/hex"
mkdir -p "$MIX_HOME" "$HEX_HOME"
mise trust .mise.toml
printf '%s\n' "$STAMP" > priv/release_id
mise exec -- elixir --version
mise exec -- mix local.hex --force --if-missing
mise exec -- mix local.rebar --force --if-missing
mise exec -- mix deps.get --check-locked
mise exec -- mix compile --force
mise exec -- mix hex.audit --format sarif --output .release-audit.json
python3 - <<'PY'
import json
with open('.release-audit.json') as f:
    audit = json.load(f)
if not audit.get('runs') or any(run.get('results') for run in audit['runs']):
    raise SystemExit('Release refused: dependency audit findings')
PY
mise exec -- mix release mjolnir --overwrite
