#!/usr/bin/env bash
# Upload a dist/ from package-cli-release.sh to the public GitHub Release.
#
#   scripts/publish-cli-github.sh <dist-dir>
#
# Repo defaults to WorldTreeNetwork/mjolnir. Override with MJOLNIR_GITHUB_REPO.
# Tag is cli-<committer-date>-<shortsha> from build-info.json's commit, unless
# MJOLNIR_CLI_TAG is set. The same commit always names the same tag, and a
# second run replaces the archive, SHA256SUMS, and build-info.json.
#
# Uploads only those three files. RELEASE_NOTES.md becomes the release body.
# The commit must already be on the GitHub repo. gh needs repo scope.
# MJOLNIR_GH can point at a stub for tests.
set -euo pipefail

DIST="${1:?usage: publish-cli-github.sh <dist-dir>}"
REPO="${MJOLNIR_GITHUB_REPO:-WorldTreeNetwork/mjolnir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$DIST" ]]; then
  echo "publish-cli-github: dist dir not found: $DIST" >&2
  exit 1
fi

gh_cmd() {
  if [[ -n "${MJOLNIR_GH:-}" ]]; then
    "$MJOLNIR_GH" "$@"
  else
    command gh "$@"
  fi
}

if [[ -z "${MJOLNIR_GH:-}" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "publish-cli-github: gh is not on PATH. Install GitHub CLI and auth it for $REPO." >&2
  exit 1
fi

info="$DIST/build-info.json"
if [[ ! -f "$info" ]]; then
  echo "publish-cli-github: missing $info" >&2
  exit 1
fi

parsed="$(python3 - "$info" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
commit = str(info.get("commit") or "")
archive = str(info.get("archive") or "")
if not commit or "/" in archive or not archive.endswith(".tar.gz"):
    raise SystemExit(f"publish-cli-github: build-info archive is not a tar.gz ({archive!r})")
print(commit)
print(archive)
PY
)"
COMMIT="$(printf '%s\n' "$parsed" | sed -n '1p')"
ARCHIVE_NAME="$(printf '%s\n' "$parsed" | sed -n '2p')"

assets=(
  "$DIST/$ARCHIVE_NAME"
  "$DIST/SHA256SUMS"
  "$DIST/build-info.json"
)
for asset in "${assets[@]}"; do
  if [[ ! -f "$asset" ]]; then
    echo "publish-cli-github: missing $asset" >&2
    exit 1
  fi
done

if [[ -n "${MJOLNIR_CLI_TAG:-}" ]]; then
  TAG="$MJOLNIR_CLI_TAG"
else
  if ! git -C "$ROOT" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
    echo "publish-cli-github: commit $COMMIT is not in $ROOT. Push it, or set MJOLNIR_CLI_TAG." >&2
    exit 1
  fi
  short="$(git -C "$ROOT" rev-parse --short=7 "$COMMIT")"
  day="$(git -C "$ROOT" log -1 --format=%cs "$COMMIT")"
  TAG="cli-${day}-${short}"
fi

title="mj CLI — ${TAG}"
notes="$DIST/RELEASE_NOTES.md"
if [[ -f "$notes" ]]; then
  note_args=(--notes-file "$notes")
else
  note_args=(--notes "$title")
fi

if gh_cmd release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh_cmd release edit "$TAG" --repo "$REPO" --title "$title" "${note_args[@]}"
  # --clobber deletes a same-named asset before the new bytes upload.
  gh_cmd release upload "$TAG" --repo "$REPO" --clobber "${assets[@]}"
else
  gh_cmd release create "$TAG" \
    --repo "$REPO" \
    --target "$COMMIT" \
    --title "$title" \
    "${note_args[@]}" \
    "${assets[@]}"
fi

if [[ -z "${MJOLNIR_GH:-}" ]]; then
  verify="$(mktemp -d)"
  trap 'rm -rf "$verify"' EXIT
  gh_cmd release download "$TAG" --repo "$REPO" --dir "$verify" --clobber \
    -p "$ARCHIVE_NAME" -p SHA256SUMS -p build-info.json
  for asset in "${assets[@]}"; do
    if ! cmp -s "$asset" "$verify/$(basename "$asset")"; then
      echo "publish-cli-github: uploaded $(basename "$asset") did not match the local file" >&2
      exit 1
    fi
    echo "Verified asset: $(basename "$asset")"
  done
fi

echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
