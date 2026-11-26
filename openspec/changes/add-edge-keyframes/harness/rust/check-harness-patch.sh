#!/usr/bin/env bash
# K4. Fails while this workspace still resolves git moq-webrtc.
# Passes when the path patch is the only moq-webrtc and no other moq crate is duplicated.
set -euo pipefail
cd "$(dirname "$0")"
if ! grep -q 'path = "../../../../../native/vendor/moq-webrtc"' Cargo.toml; then
  echo "harness still uses git moq-webrtc"
  exit 1
fi
meta=$(mktemp)
trap 'rm -f "$meta"' EXIT
cargo metadata --locked --format-version 1 > "$meta"
META_FILE="$meta" python3 - << 'PY'
import json, os, sys
doc = json.load(open(os.environ["META_FILE"]))
pin = "git+https://github.com/moq-dev/moq?rev=4a6f52248#4a6f522483168ace392718d68b58a402533c897d"
ids = {}
for p in doc["packages"]:
    if p["name"].startswith("moq-") or p["name"] in ("hang", "kio"):
        ids.setdefault(p["name"], []).append(p["id"])
errs = []
webrtc = ids.get("moq-webrtc", [])
if len(webrtc) != 1 or "native/vendor/moq-webrtc" not in webrtc[0] or not webrtc[0].startswith("path+file://"):
    errs.append("moq-webrtc id " + repr(webrtc))
for name, vals in sorted(ids.items()):
    if name == "moq-webrtc":
        continue
    if len(vals) != 1:
        errs.append(f"duplicate {name}: {vals}")
    elif name.startswith("moq-ext") or name.startswith("moq-transport"):
        continue
    elif "rev=4a6f52248#" not in vals[0]:
        errs.append(f"{name} not on pin: {vals[0]}")
if errs:
    print("\n".join(errs))
    sys.exit(1)
print(webrtc[0])
print("moq-net", ids["moq-net"][0])
PY
tree=$(cargo tree --locked -d)
# Only a duplicated package is a column-0 line. Nested moq deps of some other duplicate are not a second moq.
if echo "$tree" | grep -E '^(moq|hang|kio)' >/dev/null; then
  echo "cargo tree -d lists a moq crate"
  echo "$tree"
  exit 1
fi
blog=$(mktemp)
if ! cargo build --locked --offline --bins >"$blog" 2>&1; then
  cat "$blog"
  rm -f "$blog"
  exit 1
fi
if grep -i unused "$blog"; then
  echo "unused-patch warning"
  rm -f "$blog"
  exit 1
fi
rm -f "$blog"
echo "harness patch ok"
