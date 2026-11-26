#!/bin/bash
# Follow-up rows: Iroh announcements while a publisher is live, participant
# confinement with a reader, Chromium MoQ receipt, HTTP mint boundary.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
LOGDIR="${1:?log dir}"
mkdir -p "$LOGDIR"
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
PAIR="$ROOT/native/mjolnir_relay/target/debug/iroh-pair"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
CHROMIUM="${CHROMIUM:-/Users/dukejones/Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"
PRIV="$(mktemp -d /tmp/path-follow.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.3; pkill -P $$ 2>/dev/null || true; rm -rf "$PRIV"; }
trap cleanup EXIT
python3 - <<'PY' >"$PRIV/owner.txt"
alph = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n = int.from_bytes(bytes([9] * 32), "big")
s = ""
while n:
    n, r = divmod(n, 58)
    s = alph[r] + s
print(s)
PY
OWNER="$(cat "$PRIV/owner.txt")"
OPEN="t/${OWNER}/~open/standup"
PROT="t/${OWNER}/standup"
"$SPIKE" relay "$PRIV" >"$PRIV/relay.out" 2>&1 &
for _ in $(seq 1 80); do
  [[ -f "$PRIV/relay.txt" && -f "$PRIV/hash.txt" ]] && break
  sleep 0.25
done
ADDR="$(cat "$PRIV/relay.txt")"
IROH="$(cat "$PRIV/iroh.txt")"
HASH="$(cat "$PRIV/hash.txt")"
PORT="${ADDR##*:}"
sign() { "$SPIKE" sign "$PRIV" "$1" "$2" "$3" 180; }
T_OPEN="$(sign "$OPEN" '**' '**')"
T_OPEN_SUB="$(sign "$OPEN" '-' '**')"
T_P="$(sign "$OPEN" 'p/**' '**')"
redact() { sed -E 's/jwt=[^& ]+/jwt=REDACTED/g; s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g'; }
run() {
  local title="$1"; shift
  echo; echo "### $title"
  python3 - "$@" <<'PY' | redact
import subprocess, sys
cmd = sys.argv[1:]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=18)
    sys.stdout.write(p.stdout); sys.stdout.write(p.stderr)
    print(f"exit={p.returncode}")
except subprocess.TimeoutExpired as e:
    out = e.stdout or ""; err = e.stderr or ""
    if isinstance(out, bytes):
        out = out.decode(errors="replace"); err = err.decode(errors="replace")
    sys.stdout.write(out); sys.stdout.write(err)
    print("killed-after-18s"); print("exit=124")
PY
}
{
  echo "# follow-up evidence"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "quic=$ADDR iroh=$IROH cert_sha256=$HASH"
  echo "chromium=$("$CHROMIUM" --version 2>/dev/null | head -1)"
} >"$LOGDIR/path-follow.log"

{
  echo; echo "## Iroh announce while open publisher is live"
  rm -f "$PRIV/ready"
  "$PAIR" publish "$IROH" "$T_OPEN" "${OPEN}/open-marker" 8 "$PRIV/ready" "PAIR-OPEN" >"$PRIV/pub.out" 2>&1 &
  for _ in $(seq 1 40); do [[ -f $PRIV/ready ]] && break; sleep 0.1; done
  run "listen during publish" "$PAIR" listen "$IROH" "$T_OPEN_SUB" 3
  echo; echo "## WT participant confinement"
  "$WT" publish "$(printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$OPEN" "$T_P")" "p/track" 6 >"$PRIV/wp.out" 2>&1 &
  "$WT" publish "$(printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$OPEN" "$T_P")" "q/track" 6 >"$PRIV/wq.out" 2>&1 &
  sleep 1.2
  run "read own label p/track" "$WT" read "$(printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$OPEN" "$T_OPEN")" "p/track" 3
  run "read other label q/track" "$WT" read "$(printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$OPEN" "$T_OPEN")" "q/track" 3
  echo "### publish transcripts"
  redact <"$PRIV/wp.out"; redact <"$PRIV/wq.out"
} >>"$LOGDIR/path-follow.log" 2>&1

# Chromium
python3 - "$PRIV" "$PORT" "$HASH" "$OPEN" "$T_OPEN" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
priv, port, digest, root, token = sys.argv[1:]
js = open("/tmp/moq-sub.js", encoding="utf-8").read()
literal = f"https://127.0.0.1:{port}/{root}?jwt={token}"
encoded = literal.replace("~open", "%7Eopen")
double = literal.replace("~open", "%257Eopen")
open(f"{priv}/urls.txt","w").write("literal-path-has-tilde\nencoded-path-has-%7Eopen\ndouble-path-has-%257Eopen\n")
def page(url):
    cfg = json.dumps({"url": url, "hash": digest, "path": "open-marker", "seconds": 4})
    return f"<!doctype html><meta charset=utf-8><body><script>window.__MOQ__ = {cfg};</script><script>{js}</script>"
pages = {"/literal": page(literal), "/encoded": page(encoded), "/double": page(double)}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = pages.get(self.path, "missing")
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n).decode(errors="replace")
        name = {"/literal": "literal", "/encoded": "encoded", "/double": "double"}.get(self.headers.get("Referer","").rstrip("/").split("/")[-1], "unknown")
        # Referer is the page URL path.
        ref = self.headers.get("Referer","")
        tag = "unknown"
        for key in ("literal","encoded","double"):
            if ref.endswith("/"+key):
                tag = key
        open(f"{priv}/log-{tag}.txt","a").write(data+"\n")
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass
httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(f"{priv}/page-port","w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
for _ in $(seq 1 30); do [[ -f $PRIV/page-port ]] && break; sleep 0.1; done
PP="$(cat "$PRIV/page-port")"
# publisher for the literal MoQ read
"$WT" publish "$(printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$OPEN" "$T_OPEN")" open-marker 12 >"$PRIV/wt-moq.out" 2>&1 &
sleep 1.2
chrome_one() {
  local name="$1" path="$2"
  local udd="$PRIV/chrome-$name"
  mkdir -p "$udd"
  "$CHROMIUM" --headless=new --disable-gpu --no-first-run --user-data-dir="$udd" \
    "http://127.0.0.1:${PP}${path}" >"$PRIV/chrome-$name.out" 2>"$PRIV/chrome-$name.err" &
  local cp=$!
  for _ in $(seq 1 40); do
    [[ -s "$PRIV/log-$name.txt" ]] && break
    sleep 0.25
  done
  kill "$cp" 2>/dev/null || true
  wait "$cp" 2>/dev/null || true
  echo "### chromium $name"
  if [[ -f "$PRIV/log-$name.txt" ]]; then
    sed -E 's/jwt=[^& ]+/jwt=REDACTED/g' "$PRIV/log-$name.txt"
  else
    echo "no-log"
    tail -c 400 "$PRIV/chrome-$name.err" | sed -E 's/jwt=[^& ]+/jwt=REDACTED/g' || true
  fi
}
{
  echo; echo "## Chromium MoQ (pinned @moq/net 4a6f522, bundle /tmp/moq-sub.js)"
  echo "bundle_bytes=$(wc -c </tmp/moq-sub.js)"
  chrome_one literal /literal
  chrome_one encoded /encoded
  chrome_one double /double
  echo "### native publisher during browser"
  redact <"$PRIV/wt-moq.out"
} >>"$LOGDIR/path-follow.log" 2>&1

echo done >>"$LOGDIR/path-follow.log"
