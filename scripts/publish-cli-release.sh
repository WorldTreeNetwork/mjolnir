#!/usr/bin/env bash
# Upload a dist/ from package-cli-release.sh to a Forgejo release.
# Replaces assets that already have the same name.
#
#   FORGEJO_TOKEN=... scripts/publish-cli-release.sh <tag> <dist-dir> [api-base]
#
# api-base defaults to https://mimir.worldtree.network/api/v1
# Repo is identikey/mjolnir. The token is read from the environment only.
set -euo pipefail

TAG="${1:?usage: publish-cli-release.sh <tag> <dist-dir> [api-base]}"
DIST="${2:?dist dir}"
API_ROOT="${3:-https://mimir.worldtree.network/api/v1}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"

exec python3 - "$TAG" "$DIST" "$API_ROOT" <<'PY'
import json, os, pathlib, sys, uuid, urllib.error, urllib.request

tag, dist, api_root = sys.argv[1:]
dist = pathlib.Path(dist)
token = os.environ["FORGEJO_TOKEN"]
base = api_root.rstrip("/") + "/repos/identikey/mjolnir"
notes_path = dist / "RELEASE_NOTES.md"
notes = notes_path.read_text() if notes_path.exists() else ""

def request(path, data=None, headers=None, method=None):
    req = urllib.request.Request(
        base + path,
        data=data,
        headers={"Authorization": "token " + token, **(headers or {})},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            raw = response.read()
            if not raw:
                return None
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        raise SystemExit(f"Forgejo {error.code} {method or 'GET'} {path}: {body}") from error

release = None
try:
    release = request(f"/releases/tags/{tag}")
except SystemExit as error:
    if not str(error).startswith("Forgejo 404"):
        raise
if release is None:
    commit = json.loads((dist / "build-info.json").read_text()).get("commit")
    release = request(
        "/releases",
        json.dumps({
            "tag_name": tag,
            "target_commitish": commit,
            "name": f"mj CLI — {tag}",
            "body": notes,
            "draft": False,
            "prerelease": False,
        }).encode(),
        {"Content-Type": "application/json"},
    )
else:
    release = request(
        f"/releases/{release['id']}",
        json.dumps({"body": notes, "draft": False, "prerelease": False}).encode(),
        {"Content-Type": "application/json"},
        "PATCH",
    )

existing = {asset["name"]: asset for asset in release.get("assets") or []}
# Drop the old raw Mach-O. The download is the tar.gz named mj inside.
for stale in list(existing):
    # Previous releases attached the raw binary (no suffix), which browsers
    # save as mode 644. The downloadable file is now mj-<target>.tar.gz.
    if stale.startswith("mj-") and "." not in stale:
        request(f"/releases/{release['id']}/assets/{existing[stale]['id']}", method="DELETE")
        del existing[stale]

allowed = {"SHA256SUMS", "build-info.json"}
for path in sorted(dist.iterdir()):
    if not path.is_file():
        continue
    if path.name not in allowed and not path.name.endswith(".tar.gz"):
        continue
    if path.name in existing:
        request(f"/releases/{release['id']}/assets/{existing[path.name]['id']}", method="DELETE")
    boundary = uuid.uuid4().hex
    payload = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="attachment"; filename="{path.name}"\r\n'
        f'Content-Type: application/octet-stream\r\n\r\n'
    ).encode() + path.read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
    asset = request(
        f"/releases/{release['id']}/assets?name={path.name}",
        payload,
        {"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    download = asset["browser_download_url"].replace(
        "https://mimir.worldtree.network", "http://127.0.0.1:3000"
    )
    fetched = urllib.request.Request(download, headers={"Authorization": "token " + token})
    with urllib.request.urlopen(fetched, timeout=180) as response:
        actual = response.read()
    if actual != path.read_bytes():
        raise SystemExit(f"uploaded {path.name} did not match the local file")
    print(f"Verified asset: {path.name} {asset['browser_download_url']}")

print("Release:", release.get("html_url") or tag)
PY
