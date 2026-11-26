#!/bin/bash
# Headless Chromium MoQ subscriber against the local spike relay.
# Rebuilds /tmp/moq-sub.js from the pinned checkout copy if present.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
LOGDIR="${1:?log dir}"
mkdir -p "$LOGDIR"
if [[ -f /tmp/moq-src/net/package.json ]]; then
  cp "$ROOT/openspec/changes/add-open-room-kind/spikes/path/moq-sub.ts" /tmp/moq-src/net/moq-sub.ts
  (cd /tmp/moq-src/net && bun build moq-sub.ts --target=browser --outfile=/tmp/moq-sub.js)
fi
[[ -f /tmp/moq-sub.js ]] || { echo "no bundle" | tee "$LOGDIR/path-chromium.log"; exit 1; }
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
CHROMIUM="${CHROMIUM:-/Users/dukejones/Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"
PRIV="$(mktemp -d /tmp/path-chrome.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.2; pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$PRIV"; }
trap cleanup EXIT
python3 - <<'PY' >"$PRIV/owner.txt"
alph = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = int.from_bytes(bytes([9] * 32), "big"); s=""
while n:
    n, r = divmod(n, 58); s = alph[r] + s
print(s)
PY
OWNER="$(cat "$PRIV/owner.txt")"
OPEN="t/${OWNER}/~open/standup"
"$SPIKE" relay "$PRIV" >"$PRIV/relay.out" 2>&1 &
for _ in $(seq 1 40); do [[ -f $PRIV/relay.txt ]] && break; sleep 0.25; done
ADDR="$(cat "$PRIV/relay.txt")"
PORT="${ADDR##*:}"
HASH="$(cat "$PRIV/hash.txt")"
TOK="$("$SPIKE" sign "$PRIV" "$OPEN" '**' '**' 180)"
python3 - "$PRIV" "$PORT" "$HASH" "$OPEN" "$TOK" <<'PY' &
import json,sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
priv,port,digest,root,token=sys.argv[1:]
js=open("/tmp/moq-sub.js",encoding="utf-8").read()
def page(url):
    cfg=json.dumps({"url":url,"hash":digest,"path":"open-marker","seconds":4})
    return f"<!doctype html><body><script>window.__MOQ__={cfg};</script><script>{js}</script>"
lit=f"https://127.0.0.1:{port}/{root}?jwt={token}"
pages={"/literal":page(lit),"/encoded":page(lit.replace("~open","%7Eopen")),"/double":page(lit.replace("~open","%257Eopen"))}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b=pages.get(self.path,"missing").encode(); self.send_response(200); self.send_header("content-type","text/html"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n=int(self.headers.get("Content-Length") or 0); data=self.rfile.read(n).decode(errors="replace")
        ref=self.headers.get("Referer","")
        tag="unknown"
        for k in ("literal","encoded","double"):
            if ref.endswith("/"+k): tag=k
        open(f"{priv}/log-{tag}.txt","a").write(data+"\n")
        self.send_response(204); self.end_headers()
    def log_message(self,*a): pass
httpd=ThreadingHTTPServer(("127.0.0.1",0),H)
open(f"{priv}/page-port","w").write(str(httpd.server_address[1])); httpd.serve_forever()
PY
for _ in $(seq 1 30); do [[ -f $PRIV/page-port ]] && break; sleep 0.1; done
PP="$(cat "$PRIV/page-port")"
"$WT" publish "https://127.0.0.1:${PORT}/${OPEN}?jwt=${TOK}" open-marker 16 >"$PRIV/wt.out" 2>&1 &
sleep 1.2
for name in literal encoded double; do
  "$CHROMIUM" --headless=new --disable-gpu --no-first-run --user-data-dir="$PRIV/c-$name" "http://127.0.0.1:${PP}/$name" >/dev/null 2>"$PRIV/e-$name" &
  cp=$!
  for _ in $(seq 1 60); do
    grep -q -E 'received path=|moq-error' "$PRIV/log-$name.txt" 2>/dev/null && break
    sleep 0.25
  done
  kill $cp 2>/dev/null || true
  wait $cp 2>/dev/null || true
done
{
  echo "# chromium moq $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cert_sha256=$HASH quic=$ADDR"
  echo "bundle=pinned @moq/net 4a6f522 via bun, page posts /log"
  echo "native_publisher:"
  sed -E 's/jwt=[^& ]+/jwt=REDACTED/g' "$PRIV/wt.out"
  for name in literal encoded double; do
    echo "## $name"
    if [[ -f $PRIV/log-$name.txt ]]; then sed -E 's/jwt=[^& ]+/jwt=REDACTED/g' "$PRIV/log-$name.txt"; else echo missing; fi
  done
} >"$LOGDIR/path-chromium.log"
echo wrote "$LOGDIR/path-chromium.log"
