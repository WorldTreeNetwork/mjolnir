#!/usr/bin/env bash
# Spike e2ee-js runner. See README.md.
# usage: run.sh <workdir> <chromium|firefox> [default|lite07]
#   <workdir> holds moq/ (a copy of moq rev 4a6f52248, bun-installed), harness/ (playwright),
#   and target/release/moq-relay (built from that copy).
set -euo pipefail
W=$(cd "$1" && pwd); BROWSER=$2; MODE=${3:-default}
HERE=$(cd "$(dirname "$0")" && pwd)
COMPONENTS=${COMPONENTS:-0}

# 1. Bundle the page against the copy's workspace (so @moq/net and ../src resolve).
mkdir -p "$W/moq/js/e2ee/spike" "$W/www"
cp "$HERE/e2ee-page.ts" "$W/moq/js/e2ee/spike/"
if [ "$COMPONENTS" = 1 ]; then
  cp -f "$HERE/components-page.ts" "$HERE/bridge.ts" "$W/moq/js/e2ee/spike/"
  cp -f "$HERE/components-page.ts" "$W/moq/js/e2ee/spike/e2ee-page.ts"
fi
(cd "$W/moq/js/e2ee" && bun build spike/e2ee-page.ts --target=browser --outdir "$W/www" >/dev/null)
printf '<!doctype html><meta charset=utf-8><title>e2ee spike</title><script type=module src="e2ee-page.js"></script>' >"$W/www/index.html"

# 2. Relay config: default version list, or opt moq-lite-07-wip in on the relay.
if [ "$MODE" = lite07 ]; then
  VERS='version = ["moq-lite-07-wip", "moq-lite-06", "moq-lite-05", "moq-lite-04", "moq-lite-03", "moq-lite-02", "moq-lite-01", "moq-transport-22", "moq-transport-20", "moq-transport-18"]'
  CLIENT_VERSIONS="moq-lite-07-wip"
else
  VERS=''
  CLIENT_VERSIONS=""
fi
sed "s|@VERSIONS@|$VERS|" "$HERE/relay.toml" >"$W/relay.toml"

if lsof -nP -iUDP:4443 >/dev/null 2>&1; then echo "UDP 4443 is busy; stop the old relay first" >&2; exit 1; fi
"$W/target/release/moq-relay" "$W/relay.toml" >"$W/relay.log" 2>&1 &
RELAY=$!
python3 -m http.server 8088 --bind 127.0.0.1 --directory "$W/www" >"$W/http.log" 2>&1 &
HTTP=$!
# The relay drains for 10s on the first signal and exits on the second.
trap 'kill $HTTP 2>/dev/null; kill $RELAY 2>/dev/null; sleep 0.2; kill $RELAY 2>/dev/null; wait $RELAY 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do curl -sf http://127.0.0.1:4443/certificate.sha256 >/dev/null && break; sleep 0.2; done
HASH=$(curl -sf http://127.0.0.1:4443/certificate.sha256)
echo "relay certificate.sha256=$HASH mode=$MODE"

cd "$W/harness"
cp "$HERE/drive.mjs" .
COMPONENTS=$COMPONENTS timeout 120 node drive.mjs "$BROWSER" "http://localhost:8088/index.html" "https://localhost:4443/spike" "$HASH" $CLIENT_VERSIONS
