#!/bin/bash
# Bounded Iroh pair, in-session WT operation, and Chromium MoQ subscriber.
# Dummy keys, 127.0.0.1. Tokens stay out of the log.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
LOGDIR="${1:?log dir}"
mkdir -p "$LOGDIR"
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
PAIR="$ROOT/native/mjolnir_relay/target/debug/iroh-pair"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
CHROMIUM="${CHROMIUM:-/Users/dukejones/Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"
MOQ_JS="${MOQ_JS:-$HOME/.cargo/git/checkouts/moq-71b39088639cef96/4a6f522/js}"
PRIV="$(mktemp -d /tmp/path-pair.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.3; rm -rf "$PRIV"; }
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
  [[ -f "$PRIV/relay.txt" && -f "$PRIV/iroh.txt" && -f "$PRIV/hash.txt" ]] && break
  sleep 0.25
done
if [[ ! -f "$PRIV/relay.txt" ]]; then
  echo "RELAY_FAIL" | tee "$LOGDIR/path-pair.log"
  cat "$PRIV/relay.out" >>"$LOGDIR/path-pair.log"
  exit 1
fi
ADDR="$(cat "$PRIV/relay.txt")"
IROH="$(cat "$PRIV/iroh.txt")"
HASH="$(cat "$PRIV/hash.txt")"
PORT="${ADDR##*:}"
sign() { "$SPIKE" sign "$PRIV" "$1" "$2" "$3" 180; }
T_OPEN="$(sign "$OPEN" '**' '**')"
T_PROT="$(sign "$PROT" '**' '**')"
T_OPEN_SUB="$(sign "$OPEN" '-' '**')"
T_PROT_SUB="$(sign "$PROT" '-' '**')"
T_P="$(sign "$OPEN" 'p/**' '**')"
redact() { sed -E 's/jwt=[^& ]+/jwt=REDACTED/g; s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g'; }
note() { echo; echo "## $*"; }
run() {
  local title="$1"; shift
  echo; echo "### $title"
  python3 - "$@" <<'PY' | redact
import subprocess, sys
cmd = sys.argv[1:]
try:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    sys.stdout.write(p.stdout)
    sys.stdout.write(p.stderr)
    print(f"exit={p.returncode}")
except subprocess.TimeoutExpired as e:
    out = (e.stdout or b"")
    err = (e.stderr or b"")
    if isinstance(out, bytes):
        out = out.decode(errors="replace")
        err = err.decode(errors="replace")
    sys.stdout.write(out)
    sys.stdout.write(err)
    print("killed-after-20s")
    print("exit=124")
PY
}

{
  echo "# path pair evidence"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "quic=$ADDR iroh_endpoint=$IROH cert_sha256=$HASH"
  echo "pins moq=4a6f52248 iroh-live=747b1bd"
  echo "open_root=t/<owner>/~open/standup protected_root=t/<owner>/standup"
  echo "iroh-pair=$(shasum -a 256 "$PAIR" | awk '{print $1}')"
  echo "spike=$(shasum -a 256 "$SPIKE" | awk '{print $1}')"
  echo "wt-session=$(shasum -a 256 "$WT" | awk '{print $1}')"
} >"$LOGDIR/path-pair.log"

{
  note "Iroh own-root positive, publisher ready before subscribe"
  rm -f "$PRIV/ready-open" "$PRIV/ready-prot"
  "$PAIR" publish "$IROH" "$T_OPEN" "${OPEN}/open-marker" 8 "$PRIV/ready-open" "PAIR-OPEN" >"$PRIV/pub-open.out" 2>&1 &
  po=$!
  for _ in $(seq 1 50); do [[ -f "$PRIV/ready-open" ]] && break; sleep 0.1; done
  echo "open-publisher-ready=$( [[ -f $PRIV/ready-open ]] && echo yes || echo no )"
  run "iroh own-read open" "$PAIR" read "$IROH" "$T_OPEN" "${OPEN}/open-marker" 6 3
  "$PAIR" publish "$IROH" "$T_PROT" "${PROT}/prot-marker" 8 "$PRIV/ready-prot" "PAIR-PROT" >"$PRIV/pub-prot.out" 2>&1 &
  pp=$!
  for _ in $(seq 1 50); do [[ -f "$PRIV/ready-prot" ]] && break; sleep 0.1; done
  echo "prot-publisher-ready=$( [[ -f $PRIV/ready-prot ]] && echo yes || echo no )"
  run "iroh own-read protected" "$PAIR" read "$IROH" "$T_PROT" "${PROT}/prot-marker" 6 3
  note "Iroh cross-root reads while both publishers are announcing"
  run "iroh cross-read open token on protected absolute path" "$PAIR" read "$IROH" "$T_OPEN" "${PROT}/prot-marker" 6 2
  run "iroh cross-read protected token on open absolute path" "$PAIR" read "$IROH" "$T_PROT" "${OPEN}/open-marker" 6 2
  note "Iroh announcements"
  run "iroh announce open subscribe token" "$PAIR" listen "$IROH" "$T_OPEN_SUB" 2
  run "iroh announce protected subscribe token" "$PAIR" listen "$IROH" "$T_PROT_SUB" 2
  note "Iroh cross write: open token publishes protected absolute path; protected reader asks for it"
  "$PAIR" publish "$IROH" "$T_OPEN" "${PROT}/stolen" 6 "$PRIV/ready-stolen" "PAIR-STOLEN" >"$PRIV/pub-stolen.out" 2>&1 &
  ps=$!
  for _ in $(seq 1 40); do [[ -f "$PRIV/ready-stolen" ]] && break; sleep 0.1; done
  echo "stolen-publisher-ready-file=$( [[ -f $PRIV/ready-stolen ]] && echo yes || echo no )"
  run "iroh protected reader of stolen path" "$PAIR" read "$IROH" "$T_PROT" "${PROT}/stolen" 6 2
  echo "### publisher transcripts (no tokens)"
  redact <"$PRIV/pub-open.out"
  redact <"$PRIV/pub-prot.out"
  redact <"$PRIV/pub-stolen.out"
  wait $po $pp $ps 2>/dev/null || true
} >>"$LOGDIR/path-pair.log" 2>&1

wt_url() { printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$1" "$2"; }
{
  note "Native WT in-session operation after admission"
  "$WT" publish "$(wt_url "$OPEN" "$T_OPEN")" open-marker 6 >"$PRIV/wt-pub.out" 2>&1 &
  w=$!
  sleep 1.2
  run "wt own-read open-marker" "$WT" read "$(wt_url "$OPEN" "$T_OPEN")" open-marker 3
  run "wt admitted open session asks for sibling name prot-marker" "$WT" read "$(wt_url "$OPEN" "$T_OPEN")" prot-marker 2
  run "wt admitted open session asks for relative escape" "$WT" read "$(wt_url "$OPEN" "$T_OPEN")" "../standup/prot-marker" 2
  run "wt publish label q with grant p/** on open root" "$WT" publish "$(wt_url "$OPEN" "$T_P")" "q/track" 2
  run "wt publish own label p/track" "$WT" publish "$(wt_url "$OPEN" "$T_P")" "p/track" 2
  echo "### wt publisher"
  redact <"$PRIV/wt-pub.out"
  wait $w 2>/dev/null || true
} >>"$LOGDIR/path-pair.log" 2>&1

if [[ "${SKIP_BROWSER:-}" == 1 ]]; then
  echo "browser=skipped" >>"$LOGDIR/path-pair.log"
  exit 0
fi

# Chromium MoQ subscriber of the native publisher.
BUNDIR="$PRIV/bun"
mkdir -p "$BUNDIR/node_modules/@moq"
ln -s "$MOQ_JS/net" "$BUNDIR/node_modules/@moq/net"
ln -s "$MOQ_JS/clock" "$BUNDIR/node_modules/@moq/clock"
ln -s "$MOQ_JS/pattern" "$BUNDIR/node_modules/@moq/pattern"
ln -s "$MOQ_JS/qmux" "$BUNDIR/node_modules/@moq/qmux"
ln -s "$MOQ_JS/signals" "$BUNDIR/node_modules/@moq/signals"
( cd "$BUNDIR" && bun add pako@3.0.3 >/dev/null )
if bun build "$ROOT/openspec/changes/add-open-room-kind/spikes/path/moq-sub.ts" --target=browser --outfile="$PRIV/moq-sub.js" --packages=bundle; then
  echo "bun-bundle=ok bytes=$(wc -c <"$PRIV/moq-sub.js")" >>"$LOGDIR/path-pair.log"
else
  echo "bun-bundle=fail" >>"$LOGDIR/path-pair.log"
fi

if [[ -f "$PRIV/moq-sub.js" && -x "$CHROMIUM" ]]; then
  "$WT" publish "$(wt_url "$OPEN" "$T_OPEN")" open-marker 10 >"$PRIV/wt-moq.out" 2>&1 &
  wm=$!
  sleep 1.2
  python3 - "$PRIV" "$PORT" "$HASH" "$OPEN" "$T_OPEN" <<'PY' >"$PRIV/page.out" 2>&1
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
priv, port, digest, root, token = sys.argv[1:]
js = open(f"{priv}/moq-sub.js", encoding="utf-8").read()
url = f"https://127.0.0.1:{port}/{root}?jwt={token}"
page = """<!doctype html><meta charset=utf-8><body>
<script>window.__MOQ__ = %s;</script>
<script>%s</script>
""" % (json.dumps({"url": url, "hash": digest, "path": "open-marker", "seconds": 4}), js)
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(page.encode())
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("127.0.0.1", 0), H).serve_forever()
PY
  # python above blocks. Need page server in background. The heredoc replaced wrong.
fi
echo "page-server-setup skipped if bun failed" >>"$LOGDIR/path-pair.log"
wait 2>/dev/null || true
echo "done" >>"$LOGDIR/path-pair.log"
