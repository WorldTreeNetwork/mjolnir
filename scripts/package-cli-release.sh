#!/usr/bin/env bash
# Package a built mjolnir client so a download extracts to an executable named mj.
#
# gzip does not store the Unix mode. A browser also saves any raw binary as mode
# 644, and macOS attaches com.apple.quarantine. tar.gz keeps mode 0755, so
# `tar xzf` yields ./mj already executable.
#
# On macOS a release binary must be Developer ID signed and notarized. An ad-hoc
# signature, and an unnotarized Developer ID signature, are SIGKILL (exit 137)
# on first launch while that quarantine attribute is set.
#
# Usage:
#   scripts/package-cli-release.sh <binary> [target-triple]
#
# Writes <dist>/mj-<target>.tar.gz, SHA256SUMS, build-info.json, RELEASE_NOTES.md.
# Dist defaults to <repo>/dist. Override with MJOLNIR_CLI_DIST.
#
# Signing (Darwin only):
#   MJOLNIR_CLI_SIGN=developer-id   default. Identity below, hardened runtime, timestamp.
#   MJOLNIR_CLI_SIGN=adhoc          local experiments only. Not a downloadable release.
#   MJOLNIR_CLI_SIGN=skip           tests, and Linux CI.
#   MJOLNIR_NOTARY_PROFILE=mjolnir  notarytool keychain profile.
#   MJOLNIR_NOTARY_REQUIRED=1       default for developer-id. Set 0 to emit an
#                                   unnotarized archive anyway.
#
# GitHub: a notarized macOS archive is uploaded to the public release
# WorldTreeNetwork/mjolnir, tag cli-<commit-date>-<shortsha>.
#   MJOLNIR_CLI_GITHUB=0            do not upload.
#   MJOLNIR_CLI_GITHUB=1            upload even when the archive is not notarized.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:?usage: package-cli-release.sh <binary> [target-triple]}"
TARGET="${2:-}"
DIST="${MJOLNIR_CLI_DIST:-$ROOT/dist}"
DEVELOPER_ID="Developer ID Application: Identikey Inc (3GZ9RHNYZM)"
TEAM_ID="3GZ9RHNYZM"
IDENTIFIER="network.worldtree.mj"
NOTARY_PROFILE="${MJOLNIR_NOTARY_PROFILE:-mjolnir}"

if [[ ! -f "$BINARY" ]]; then
  echo "package-cli-release: binary not found: $BINARY" >&2
  exit 1
fi

if [[ -z "$TARGET" ]]; then
  TARGET="$(rustc -vV | awk '/^host:/{print $2}')"
fi

case "$(uname -s)" in
  Darwin) default_sign=developer-id ;;
  *) default_sign=skip ;;
esac
SIGN="${MJOLNIR_CLI_SIGN:-$default_sign}"
if [[ "$SIGN" == "developer-id" ]]; then
  NOTARY_REQUIRED="${MJOLNIR_NOTARY_REQUIRED:-1}"
else
  NOTARY_REQUIRED="${MJOLNIR_NOTARY_REQUIRED:-0}"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
install -m 0755 "$BINARY" "$STAGE/mj"

signed=false
notarized=false

sign_developer_id() {
  if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID" >/dev/null; then
    echo "package-cli-release: missing codesign identity: $DEVELOPER_ID" >&2
    exit 1
  fi
  codesign --force --options runtime --timestamp \
    --identifier "$IDENTIFIER" \
    --sign "$DEVELOPER_ID" \
    "$STAGE/mj"
  codesign --verify --verbose=2 "$STAGE/mj"
  signed=true
}

notarize() {
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    if [[ "$NOTARY_REQUIRED" == "1" ]]; then
      cat >&2 <<EOF
package-cli-release: no notarytool profile "$NOTARY_PROFILE".
A Developer ID binary that is not notarized is killed on first launch when
the browser sets quarantine (spctl: Unnotarized Developer ID, exit 137).
Store the Apple credentials once, then rerun:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id APPLE_ID --team-id $TEAM_ID
EOF
      exit 1
    fi
    echo "package-cli-release: skipping notarization (profile $NOTARY_PROFILE not found)" >&2
    return 0
  fi
  local zip="$STAGE/mj.zip"
  ditto -c -k --keepParent "$STAGE/mj" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  # stapler only attaches tickets to app bundles, UDIF disk images, and
  # flat installer packages. A standalone Mach-O is rejected with error 73
  # (it tries to write mj/Contents/CodeResources). Gatekeeper still allows
  # a quarantined first launch by fetching this ticket online.
  notarized=true
  rm -f "$zip"
}

# Version comes from the input binary. Running the signed copy here would
# count as its first launch and hide a Gatekeeper quarantine failure.
version="$("$BINARY" --version 2>/dev/null | head -n 1 || true)"

case "$SIGN" in
  developer-id)
    sign_developer_id
    notarize
    ;;
  adhoc)
    codesign --force --sign - --identifier "$IDENTIFIER" "$STAGE/mj"
    signed=true
    echo "package-cli-release: ad-hoc signature. Browser downloads of this binary are killed." >&2
    ;;
  skip) ;;
  *)
    echo "package-cli-release: unknown MJOLNIR_CLI_SIGN=$SIGN" >&2
    exit 1
    ;;
esac

commit="${MJOLNIR_CLI_COMMIT:-}"
if [[ -z "$commit" ]]; then
  commit="$(git -C "$ROOT" rev-parse HEAD)"
fi

if [[ "$notarized" == true ]]; then
  mac_note="$(cat <<EOF
macOS

This build is signed with Developer ID and notarized. A quarantined
browser download is allowed to run while the Mac can reach Apple to
fetch the ticket. If macOS kills mj (exit 137), usually while offline:

  xattr -d com.apple.quarantine mj
EOF
)"
else
  mac_note="$(cat <<EOF
macOS

This copy is not notarized. Gatekeeper kills a quarantined browser
download on first launch (exit 137). A release archive is notarized
before it is published. To run this copy anyway:

  xattr -d com.apple.quarantine mj
EOF
)"
fi

cat >"$STAGE/INSTALL.txt" <<EOF
mj — Mjolnir CLI ($TARGET)

This archive contains one executable named mj.
Plain gzip is not used: it does not keep the executable bit, and a browser
saves a raw binary as mode 644.

Install

  tar xzf mj-${TARGET}.tar.gz
  sudo install -m 755 mj /usr/local/bin/mj

/usr/local/bin is on the default PATH (/etc/paths on macOS, the usual
PATH on Linux). If that directory does not exist yet:

  sudo mkdir -p /usr/local/bin

Then:

  mj --version
  mj login

The default API is https://api.vm.worldtree.network.

$mac_note
EOF
chmod 0644 "$STAGE/INSTALL.txt"

mkdir -p "$DIST"
ARCHIVE="$DIST/mj-${TARGET}.tar.gz"
rm -f "$ARCHIVE"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGE" mj INSTALL.txt

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
mj_sha="$(sha256 "$STAGE/mj")"
archive_sha="$(sha256 "$ARCHIVE")"
{
  printf '%s  %s\n' "$archive_sha" "$(basename "$ARCHIVE")"
  printf '%s  %s\n' "$mj_sha" "mj"
} >"$DIST/SHA256SUMS"

notes="$DIST/RELEASE_NOTES.md"
cat >"$notes" <<EOF
Production CLI archive for $TARGET at ${commit}.

Download \`mj-${TARGET}.tar.gz\`. It extracts to an executable named \`mj\` and to \`INSTALL.txt\`.

\`\`\`
tar xzf mj-${TARGET}.tar.gz
sudo install -m 755 mj /usr/local/bin/mj
mj --version
\`\`\`

Verify with \`shasum -a 256 -c SHA256SUMS\` before install. The \`mj\` line is the binary inside the archive; the other line is the archive itself.

macOS builds are signed with $DEVELOPER_ID ($([[ "$notarized" == true ]] && echo notarized || echo 'not notarized')).
EOF

export COMMIT="$commit" TARGET="$TARGET" VERSION="$version" ARCHIVE="$ARCHIVE" \
  ARCHIVE_SHA="$archive_sha" MJ_SHA="$mj_sha" SIGNED="$signed" NOTARIZED="$notarized" \
  DEVELOPER_ID="$DEVELOPER_ID" IDENTIFIER="$IDENTIFIER"
python3 - "$DIST/build-info.json" <<'PY'
import json, os, sys
out = {
  "commit": os.environ["COMMIT"],
  "target": os.environ["TARGET"],
  "version": os.environ.get("VERSION") or None,
  "archive": os.path.basename(os.environ["ARCHIVE"]),
  "archive_sha256": os.environ["ARCHIVE_SHA"],
  "mj_sha256": os.environ["MJ_SHA"],
  "signed": os.environ["SIGNED"] == "true",
  "notarized": os.environ["NOTARIZED"] == "true",
  "developer_id": os.environ["DEVELOPER_ID"] if os.environ["SIGNED"] == "true" else None,
  "identifier": os.environ["IDENTIFIER"] if os.environ["SIGNED"] == "true" else None,
}
with open(sys.argv[1], "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
PY

# Skip-sign packages (the contract test, Linux CI) do not publish.
# A notarized macOS archive does. MJOLNIR_CLI_GITHUB=1 forces it.
if [[ "${MJOLNIR_CLI_GITHUB:-}" == "1" ]] || { [[ "$notarized" == true ]] && [[ "${MJOLNIR_CLI_GITHUB:-}" != "0" ]]; }; then
  "$ROOT/scripts/publish-cli-github.sh" "$DIST" >&2
fi

echo "$ARCHIVE"
