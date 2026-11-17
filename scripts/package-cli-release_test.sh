#!/usr/bin/env bash
# Packaging contract: the archive member is named mj and is mode 0755.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/src" <<'EOF'
#!/bin/sh
echo mj-ok
EOF
chmod 644 "$tmp/src"

archive="$(
  MJOLNIR_CLI_DIST="$tmp/dist" \
  MJOLNIR_CLI_SIGN=skip \
  MJOLNIR_CLI_COMMIT=testcommit \
  "$ROOT/scripts/package-cli-release.sh" "$tmp/src" test-target
)"

python3 - "$archive" <<'PY'
import sys, tarfile
archive = sys.argv[1]
with tarfile.open(archive, "r:gz") as tar:
    names = tar.getnames()
    assert set(names) == {"mj", "INSTALL.txt"}, names
    mode = tar.getmember("mj").mode & 0o777
    assert mode == 0o755, oct(mode)
    text = tar.extractfile("INSTALL.txt").read().decode()
    assert "executable named mj" in text
    assert "tar xzf" in text
PY

tar -xzf "$archive" -C "$tmp"
test -x "$tmp/mj"
test "$("$tmp/mj")" = "mj-ok"
test -f "$tmp/dist/SHA256SUMS"
test -f "$tmp/dist/build-info.json"
grep -q 'mj-test-target.tar.gz' "$tmp/dist/SHA256SUMS"
grep -q '"notarized": false' "$tmp/dist/build-info.json"

echo "package-cli-release ok: $archive"
