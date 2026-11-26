#!/usr/bin/env bash
# K2. Compare native/vendor/moq-webrtc with moq pin 4a6f52248.
# Fails while the directory is absent. With an empty patches/, src matches upstream.
# A patch under patches/ is reversed before the byte compare, so the check sees upstream.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
vendor=$root/native/vendor/moq-webrtc
pin=4a6f522483168ace392718d68b58a402533c897d
short=4a6f52248
if [ ! -d "$vendor/src" ]; then
  echo "missing $vendor"
  exit 1
fi
checkout=${MOQ_PIN_CHECKOUT:-}
if [ -z "$checkout" ]; then
  for d in "$HOME"/.cargo/git/checkouts/moq-*/4a6f522; do
    if [ -d "$d/rs/moq-webrtc/src" ]; then checkout=$d; break; fi
  done
fi
if [ -z "${checkout:-}" ] || [ ! -d "$checkout/rs/moq-webrtc/src" ]; then
  fetch=${MOQ_PIN_FETCH:-/tmp/moq-pin-4a6f522}
  if [ ! -d "$fetch/rs/moq-webrtc/src" ]; then
    rm -rf "$fetch"
    git clone --depth 1 --filter=blob:none --sparse "https://github.com/moq-dev/moq" "$fetch"
    git -C "$fetch" fetch --depth 1 origin "$pin"
    git -C "$fetch" checkout "$pin"
    git -C "$fetch" sparse-checkout set rs/moq-webrtc LICENSE-MIT LICENSE-APACHE
  fi
  checkout=$fetch
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$vendor/src" "$work/src"
cp -f "$vendor/CHANGELOG.md" "$vendor/MIGRATE.md" "$vendor/clippy.toml" "$vendor/Cargo.toml" "$work/"
notice='Modified by the Mjolnir contributors for World Tree Network Foundation in 2026'
shopt -s nullglob
for patch in "$vendor/patches"/*.patch; do
  patch -d "$work" -p1 -R --batch < "$patch"
done
python3 - "$checkout" "$work" "$vendor" "$notice" << 'PY'
import pathlib, sys, tomllib
pin, work, vendor = map(pathlib.Path, sys.argv[1:4])
notice = sys.argv[4]
errors = []
for name in ("src", "CHANGELOG.md", "MIGRATE.md", "clippy.toml"):
    a = pin / "rs" / "moq-webrtc" / name
    b = work / name
    if a.is_dir():
        files = sorted(p.relative_to(a) for p in a.rglob("*") if p.is_file())
        other = sorted(p.relative_to(b) for p in b.rglob("*") if p.is_file())
        if files != other:
            errors.append(f"{name} file list differs")
        for rel in files:
            if (a/rel).read_bytes() != (b/rel).read_bytes():
                errors.append(f"{name}/{rel} differs from the pin")
    else:
        if a.read_bytes() != b.read_bytes():
            errors.append(f"{name} differs from the pin")
for name in ("LICENSE-MIT", "LICENSE-APACHE"):
    if (vendor/name).read_bytes() != (pin/name).read_bytes():
        errors.append(f"{name} differs from the moq root")
manifest = tomllib.loads((vendor/"Cargo.toml").read_text())
pkg = manifest["package"]
if pkg.get("version") != "0.3.12" or pkg.get("rust-version") != "1.91":
    errors.append("version or rust-version")
if manifest.get("features") != {"default": ["server"], "server": ["dep:axum"]}:
    errors.append("features table")
if "lints" in manifest or "workspace-hack" in manifest.get("dev-dependencies", {}):
    errors.append("lints or workspace-hack still present")
deps = manifest["dependencies"]
dev = manifest["dev-dependencies"]
expect = {
    "axum": {"version": "0.8", "optional": True, "default-features": False, "features": ["form", "http1", "json", "matched-path", "original-uri", "query", "tokio", "tracing"]},
    "str0m": {"version": "0.25", "default-features": False},
    "reqwest": {"version": "0.13", "default-features": False, "features": ["rustls-no-provider"]},
    "bytes": "1", "thiserror": "2", "tracing": "0.1", "url": "2",
    "rind-str0m": "0.25.2",
}
for key, spec in expect.items():
    if deps.get(key) != spec:
        errors.append(f"dependency {key}: {deps.get(key)!r}")
git = "https://github.com/moq-dev/moq"
rev = "4a6f52248"
def git_dep(name, version, **extra):
    got = deps[name]
    if got.get("git") != git or got.get("rev") != rev or got.get("version") != version:
        errors.append(f"git dep {name}")
    for k, v in extra.items():
        if got.get(k) != v:
            errors.append(f"{name} {k}")
git_dep("moq-crypto", "0.0.11", **{"default-features": False, "features": ["provider"]})
git_dep("moq-tokio", "0.19.23", **{"default-features": False})
git_dep("kio", "0.6.2", features=["runtime"])
git_dep("moq-mux", "0.10.11", features=["async"])
git_dep("moq-net", "0.3.10")
git_dep("hang", "0.21.11")
if deps["tokio"].get("version") != "1.48" or "full" not in deps["tokio"].get("features", []):
    errors.append("tokio")
if deps["uuid"].get("version") != "1.26" or deps["uuid"].get("features") != ["v4"]:
    errors.append("uuid")
if dev["moq-tokio"].get("git") != git or "test-util" not in dev["tokio"].get("features", []):
    errors.append("dev-dependencies")
if dev["rind"].get("version") != "0.3.1" or dev.get("tracing-test") != "0.2":
    errors.append("rind or tracing-test")
# Files that differ from upstream, and the manifest, carry the notice.
changed = []
src_pin = pin / "rs" / "moq-webrtc" / "src"
for path in (vendor/"src").rglob("*"):
    if path.is_file():
        rel = path.relative_to(vendor/"src")
        if not (src_pin/rel).is_file() or path.read_bytes() != (src_pin/rel).read_bytes():
            changed.append(path)
changed.append(vendor/"Cargo.toml")
for path in changed:
    if notice not in path.read_text(errors="replace"):
        errors.append(f"missing modification notice: {path.relative_to(vendor)}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("vendored moq-webrtc matches pin", "4a6f52248")
PY
