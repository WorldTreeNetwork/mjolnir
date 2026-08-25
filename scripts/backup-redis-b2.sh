#!/usr/bin/env bash
#
# backup-redis-b2.sh — quiesced copy of the Redis data dir to B2.
#
# Stop mjolnir-redis, rclone the dir, start. Named downtime: seconds.
# Restore: docs/runbooks/host-redis.md
#
# Usage:
#   backup-redis-b2.sh [--dry-run]
#
# Environment:
#   REDIS_DATA_DIR  default: /var/lib/mjolnir/redis
#   B2_REMOTE       default: b2
#   B2_BUCKET       default: mimir-backups
#   B2_PREFIX       default: mjolnir-redis/<hostname>
set -euo pipefail

REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/mjolnir/redis}"
B2_REMOTE="${B2_REMOTE:-b2}"
B2_BUCKET="${B2_BUCKET:-mimir-backups}"
B2_PREFIX="${B2_PREFIX:-mjolnir-redis/$(hostname)}"
RCLONE="${RCLONE:-rclone}"
UNIT="${REDIS_UNIT:-mjolnir-redis}"

DRY=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY=1
fi

DEST="${B2_REMOTE}:${B2_BUCKET}/${B2_PREFIX}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d /tmp/mjolnir-redis.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

if [[ ! -d "$REDIS_DATA_DIR" ]]; then
  echo "backup-redis-b2: no data dir at $REDIS_DATA_DIR" >&2
  exit 1
fi

if [[ "$DRY" -eq 1 ]]; then
  echo "backup-redis-b2: dry-run would stop $UNIT, copy $REDIS_DATA_DIR -> $DEST/${STAMP}/, start"
  exit 0
fi

WAS_ACTIVE=0
if systemctl is-active --quiet "$UNIT"; then
  WAS_ACTIVE=1
  echo "backup-redis-b2: stopping $UNIT"
  systemctl stop "$UNIT"
fi

SNAP="${WORKDIR}/${STAMP}"
mkdir -p "$SNAP"
echo "backup-redis-b2: copying ${REDIS_DATA_DIR} -> ${SNAP}"
cp -a "$REDIS_DATA_DIR/." "$SNAP/"
rm -f "$SNAP/.install-hash"

if [[ "$WAS_ACTIVE" -eq 1 ]]; then
  echo "backup-redis-b2: starting $UNIT"
  systemctl start "$UNIT"
fi

echo "backup-redis-b2: rclone ${SNAP} -> ${DEST}/${STAMP}/"
"$RCLONE" copy "$SNAP" "${DEST}/${STAMP}/"
echo "backup-redis-b2: done"
