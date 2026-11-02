#!/usr/bin/env bash
# Fixture check for backup-sites-b2.sh excludes. No network, no real rclone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/backup-sites-b2.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SITES="$WORK/sites"
mkdir -p \
  "$SITES/plaintext-cache/x" \
  "$SITES/keyspace/_opaque/secrets/pat" \
  "$SITES/keyspace/_opaque/vms/vm-1" \
  "$SITES/keyspace/fp58/sites" \
  "$SITES/recordings" \
  "$SITES/blob/b3"
printf 'derivable' > "$SITES/plaintext-cache/x/page"
printf 'secret' > "$SITES/keyspace/_opaque/secrets/pat/value"
printf 'tmp' > "$SITES/keyspace/_opaque/secrets/pat/value.tmp"
printf 'nsec' > "$SITES/keyspace/_opaque/vms/vm-1/identity"
printf 'envelope' > "$SITES/keyspace/fp58/sites/HEAD"
printf '{}' > "$SITES/recordings/h.json"
printf 'chunk' > "$SITES/blob/b3/abc"

FAKE="$WORK/rclone"
LIST="$WORK/copied"
cat > "$FAKE" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
src=""
excludes=()
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--exclude" ]]; then
    excludes+=("$arg")
  fi
  prev="$arg"
  if [[ -d "$arg" ]]; then
    src="$arg"
  fi
done
if [[ -z "$src" ]]; then
  echo "fake rclone: no source dir in: $*" >&2
  exit 1
fi
: > "${RCLONE_LIST:?}"
while IFS= read -r -d '' path; do
  rel="${path#"$src"/}"
  skip=0
  for pattern in "${excludes[@]}"; do
    # rclone '**' matches across slashes. Anchor at the transfer root.
    regex="^${pattern//\*\*/.*}$"
    if [[ "$rel" =~ $regex ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 0 ]]; then
    printf '%s\n' "$rel" >> "$RCLONE_LIST"
  fi
done < <(find "$src" -type f -print0)
EOF
chmod +x "$FAKE"

SITES_ROOT="$SITES" B2_REMOTE="b2" B2_BUCKET="bucket" B2_PREFIX="prefix" \
  RCLONE="$FAKE" RCLONE_LIST="$LIST" \
  "$SCRIPT" --dry-run

for want in \
  "keyspace/fp58/sites/HEAD" \
  "recordings/h.json" \
  "blob/b3/abc"
do
  grep -qx "$want" "$LIST"
done

for banned in \
  "plaintext-cache/x/page" \
  "keyspace/_opaque/secrets/pat/value" \
  "keyspace/_opaque/secrets/pat/value.tmp" \
  "keyspace/_opaque/vms/vm-1/identity"
do
  if grep -qx "$banned" "$LIST"; then
    echo "copied excluded path: $banned" >&2
    exit 1
  fi
done

echo "backup-sites-b2_test: ok"
