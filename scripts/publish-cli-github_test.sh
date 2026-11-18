#!/usr/bin/env bash
# The GitHub publisher uploads only the archive, checksum, and build-info.
# A skip-sign package does not call gh. An explicit publish does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2" = "release view" ]; then
  exit "${GH_VIEW_RC:-1}"
fi
exit 0
EOF
chmod 755 "$tmp/gh"

commit="$(git -C "$ROOT" rev-parse HEAD)"
short="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
day="$(git -C "$ROOT" log -1 --format=%cs HEAD)"
tag="cli-${day}-${short}"

mkdir -p "$tmp/dist"
printf 'archive-bytes\n' >"$tmp/dist/mj-test.tar.gz"
printf 'sums\n' >"$tmp/dist/SHA256SUMS"
printf 'notes\n' >"$tmp/dist/RELEASE_NOTES.md"
printf 'do-not-upload\n' >"$tmp/dist/publish-cli-github.sh"
python3 - "$tmp/dist/build-info.json" "$commit" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"commit": sys.argv[2], "archive": "mj-test.tar.gz"}, fh)
PY

GH_LOG="$tmp/create.log" GH_VIEW_RC=1 MJOLNIR_GH="$tmp/gh" \
  "$ROOT/scripts/publish-cli-github.sh" "$tmp/dist" >"$tmp/create.out"
grep -q "release create ${tag} --repo WorldTreeNetwork/mjolnir --target ${commit} --title mj CLI — ${tag} --notes-file $tmp/dist/RELEASE_NOTES.md $tmp/dist/mj-test.tar.gz $tmp/dist/SHA256SUMS $tmp/dist/build-info.json" "$tmp/create.log"
grep -q "https://github.com/WorldTreeNetwork/mjolnir/releases/tag/${tag}" "$tmp/create.out"
if grep -q 'publish-cli-github.sh' "$tmp/create.log"; then
  echo "publisher uploaded a file outside the allowlist" >&2
  exit 1
fi
if grep -q 'release upload' "$tmp/create.log"; then
  echo "missing release took the update path" >&2
  exit 1
fi

GH_LOG="$tmp/update.log" GH_VIEW_RC=0 MJOLNIR_GH="$tmp/gh" \
  "$ROOT/scripts/publish-cli-github.sh" "$tmp/dist" >"$tmp/update.out"
grep -q "release edit ${tag} --repo WorldTreeNetwork/mjolnir --title mj CLI — ${tag} --notes-file $tmp/dist/RELEASE_NOTES.md" "$tmp/update.log"
grep -q "release upload ${tag} --repo WorldTreeNetwork/mjolnir --clobber $tmp/dist/mj-test.tar.gz $tmp/dist/SHA256SUMS $tmp/dist/build-info.json" "$tmp/update.log"
if grep -q 'release create' "$tmp/update.log"; then
  echo "existing release took the create path" >&2
  exit 1
fi

cat >"$tmp/src" <<'EOF'
#!/bin/sh
echo mj-ok
EOF
chmod 644 "$tmp/src"

cat >"$tmp/poison-gh" <<'EOF'
#!/bin/sh
echo "gh invoked" >> "$GH_LOG"
exit 97
EOF
chmod 755 "$tmp/poison-gh"

GH_LOG="$tmp/poison.log"
archive="$(
  PATH="$tmp:$PATH" \
  MJOLNIR_GH="$tmp/poison-gh" \
  MJOLNIR_CLI_DIST="$tmp/skip-dist" \
  MJOLNIR_CLI_SIGN=skip \
  MJOLNIR_CLI_COMMIT=testcommit \
  "$ROOT/scripts/package-cli-release.sh" "$tmp/src" test-target
)"
test -f "$archive"
if [[ -s "$tmp/poison.log" ]]; then
  echo "skip-sign package invoked gh" >&2
  exit 1
fi

: >"$tmp/hook.log"
hook_archive="$(
  GH_LOG="$tmp/hook.log" \
  GH_VIEW_RC=0 \
  MJOLNIR_GH="$tmp/gh" \
  MJOLNIR_CLI_GITHUB=1 \
  MJOLNIR_CLI_TAG=cli-hook \
  MJOLNIR_CLI_DIST="$tmp/hook-dist" \
  MJOLNIR_CLI_SIGN=skip \
  MJOLNIR_CLI_COMMIT=testcommit \
  "$ROOT/scripts/package-cli-release.sh" "$tmp/src" hook-target
)"
test "$hook_archive" = "$tmp/hook-dist/mj-hook-target.tar.gz"
grep -q "release upload cli-hook --repo WorldTreeNetwork/mjolnir --clobber $tmp/hook-dist/mj-hook-target.tar.gz $tmp/hook-dist/SHA256SUMS $tmp/hook-dist/build-info.json" "$tmp/hook.log"
# The package contract is one stdout line: the archive path.
test "$(printf '%s\n' "$hook_archive" | wc -l | tr -d ' ')" = "1"

echo "publish-cli-github ok"
