#!/usr/bin/env bash
#
# backup-sites-b2.sh — back up the IdentiKey Sites store to Backblaze B2.
#
# Implements the durability half of the Sites design
# (docs/plans/initiatives/identikey-sites.md §4, §8) and beads mjolnir-9bq.2.
#
# WHY rclone copy (not sync): the Sites chunk store is content-addressed and
# immutable — chunks under blob/b3/ and manifests/ are never rewritten, only
# added or garbage-collected. `copy` is append-only: it never deletes on the
# destination, so a GC on the host can never propagate a delete to the backup.
# The B2 remote is also configured hard_delete=false, so even overwrites of the
# mutable HEAD records under keyspace/ retain prior versions. This makes the
# backup strictly additive and safe to run unattended.
#
# The plaintext-cache/ subtree (if present) is excluded — it is a derivable
# optimization, not source-of-truth data.
#
# Usage:
#   backup-sites-b2.sh [--dry-run]
#
# Environment overrides:
#   SITES_ROOT   default: /var/lib/mjolnir/btrfs/@sites
#   B2_REMOTE    default: b2                  (rclone remote name)
#   B2_BUCKET    default: mimir-backups       (matches existing forgejo backups)
#   B2_PREFIX    default: mjolnir-sites/<hostname>
#   RCLONE       default: rclone
set -euo pipefail

SITES_ROOT="${SITES_ROOT:-/var/lib/mjolnir/btrfs/@sites}"
B2_REMOTE="${B2_REMOTE:-b2}"
B2_BUCKET="${B2_BUCKET:-mimir-backups}"
B2_PREFIX="${B2_PREFIX:-mjolnir-sites/$(hostname)}"
RCLONE="${RCLONE:-rclone}"

DRY_RUN=()
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=(--dry-run)
fi

if [[ ! -d "$SITES_ROOT" ]]; then
  echo "backup-sites-b2: SITES_ROOT does not exist: $SITES_ROOT" >&2
  echo "backup-sites-b2: nothing to back up (no sites published yet?) — exiting 0" >&2
  exit 0
fi

DEST="${B2_REMOTE}:${B2_BUCKET}/${B2_PREFIX}"

echo "backup-sites-b2: copying ${SITES_ROOT} -> ${DEST}"
exec "$RCLONE" copy "$SITES_ROOT" "$DEST" \
  "${DRY_RUN[@]}" \
  --exclude 'plaintext-cache/**' \
  --fast-list \
  --transfers 8 \
  --checkers 16 \
  --stats 30s \
  --stats-one-line \
  --log-level INFO
