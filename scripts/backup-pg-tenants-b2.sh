#!/usr/bin/env bash
#
# backup-pg-tenants-b2.sh — pg_dump each declared sidecar tenant to B2.
#
# Off-host sink (forgejo-backup shape). Not a path under /var/lib/mjolnir/pg.
# Restore: docs/runbooks/host-postgres-tenants.md
#
# Usage:
#   backup-pg-tenants-b2.sh [--dry-run]
#
# Environment:
#   TENANTS_FILE   default: /var/lib/mjolnir/pg-tenants.json
#   PG_SOCKET_DIR  default: /var/run/mjolnir
#   PG_DUMP_ROLE   default: mjolnir_admin
#   B2_REMOTE      default: b2
#   B2_BUCKET      default: mimir-backups
#   B2_PREFIX      default: mjolnir-pg-tenants/<hostname>
set -euo pipefail

TENANTS_FILE="${TENANTS_FILE:-/var/lib/mjolnir/pg-tenants.json}"
PG_SOCKET_DIR="${PG_SOCKET_DIR:-/var/run/mjolnir}"
PG_DUMP_ROLE="${PG_DUMP_ROLE:-mjolnir_admin}"
B2_REMOTE="${B2_REMOTE:-b2}"
B2_BUCKET="${B2_BUCKET:-mimir-backups}"
B2_PREFIX="${B2_PREFIX:-mjolnir-pg-tenants/$(hostname)}"
RCLONE="${RCLONE:-rclone}"
PG_DUMP="${PG_DUMP:-pg_dump}"

DRY=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY=1
fi

if [[ ! -f "$TENANTS_FILE" ]]; then
  echo "backup-pg-tenants-b2: no tenants file at $TENANTS_FILE — nothing to dump" >&2
  exit 0
fi

DEST="${B2_REMOTE}:${B2_BUCKET}/${B2_PREFIX}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d /tmp/mjolnir-pg-tenants.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# names from {"name":"..."} objects; jq optional
names=()
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(jq -r '.[].name' "$TENANTS_FILE")
else
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(python3 -c 'import json,sys; print("\n".join(x["name"] for x in json.load(open(sys.argv[1]))))' "$TENANTS_FILE")
fi

if [[ ${#names[@]} -eq 0 ]]; then
  echo "backup-pg-tenants-b2: tenant list empty" >&2
  exit 0
fi

for name in "${names[@]}"; do
  out="${WORKDIR}/${name}-${STAMP}.sql"
  echo "backup-pg-tenants-b2: dumping ${name} -> ${out}"
  if [[ "$DRY" -eq 1 ]]; then
    echo "backup-pg-tenants-b2: dry-run skip dump ${name}"
    continue
  fi
  "$PG_DUMP" -h "$PG_SOCKET_DIR" -U "$PG_DUMP_ROLE" -d "$name" --no-owner --format=plain >"$out"
done

if [[ "$DRY" -eq 1 ]]; then
  echo "backup-pg-tenants-b2: dry-run skip rclone ${DEST}"
  exit 0
fi

echo "backup-pg-tenants-b2: copying ${WORKDIR} -> ${DEST}"
"$RCLONE" copy "$WORKDIR" "$DEST" --include "*.sql"
echo "backup-pg-tenants-b2: done"
