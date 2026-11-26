#!/bin/bash
# Local path-marker transport spike. Dummy keys, 127.0.0.1 only.
# Usage: live.sh <log-dir>
# Writes a redacted transcript. Tokens never go to the log.
set -u
# The relay is a background job of this shell. A bare `wait` would block on it.
wait_jobs() { local p; for p in "$@"; do wait "$p" 2>/dev/null || true; done; }
LOGDIR="${1:?log dir}"
mkdir -p "$LOGDIR"
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
IPUB="$ROOT/native/mjolnir_relay/target/debug/examples/iroh-publish"
ISUB="$ROOT/native/mjolnir_relay/target/debug/examples/iroh-subscribe"
CHROMIUM="${CHROMIUM:-/Users/dukejones/Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"
PRIV="$(mktemp -d /tmp/path-kind.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.4; rm -rf "$PRIV"; }
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
  echo "RELAY_FAIL" | tee "$LOGDIR/path-live.log"
  cat "$PRIV/relay.out" >>"$LOGDIR/path-live.log"
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
T_OPEN_PUB="$(sign "$OPEN" 'open-marker' '**')"
T_WIDE="$(sign "t/${OWNER}" '**' '**')"

redact() { sed -E 's/jwt=[^& ]+/jwt=REDACTED/g'; }

{
  echo "# path-marker live transport"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "quic=$ADDR iroh_endpoint=$IROH cert_sha256=$HASH"
  echo "open_root=t/<owner>/~open/standup protected_root=t/<owner>/standup"
  echo "relay=production spawn_web_decider + TokenPolicy (no kind claim, no patched verifier)"
  echo "spike=$("$SPIKE" --help 2>&1 | head -1 || true)"
  echo
} >"$LOGDIR/path-live.log"

note() { echo; echo "## $*"; }

run() {
  local name="$1"; shift
  echo
  echo "### $name"
  local out ec
  set +e
  # 12s bound. iroh-subscribe can block inside subscribe() before its own timer.
  out="$(python3 -c 'import subprocess,sys
p=subprocess.Popen(sys.argv[1:])
try:
    raise SystemExit(p.wait(timeout=12))
except subprocess.TimeoutExpired:
    p.kill()
    print("killed-after-12s")
    raise SystemExit(124)' "$@" 2>&1)"
  ec=$?
  set -e
  printf '%s\n' "$out" | redact
  echo "exit=$ec"
}

wt_url() {
  local root="$1" token="$2"
  printf 'https://127.0.0.1:%s/%s?jwt=%s' "$PORT" "$root" "$token"
}

# Native WebTransport
{
  note "native WebTransport (wt-session), 4s publish / 3s read"
  run "wt publish open-marker on open root" "$WT" publish "$(wt_url "$OPEN" "$T_OPEN")" open-marker 4 &
  p1=$!
  run "wt publish prot-marker on protected root" "$WT" publish "$(wt_url "$PROT" "$T_PROT")" prot-marker 4 &
  p2=$!
  sleep 1.2
  run "wt own-read open-marker" "$WT" read "$(wt_url "$OPEN" "$T_OPEN")" open-marker 3 &
  r1=$!
  run "wt own-read prot-marker" "$WT" read "$(wt_url "$PROT" "$T_PROT")" prot-marker 3 &
  r2=$!
  run "wt cross-read open token reads prot path via protected URL" "$WT" read "$(wt_url "$PROT" "$T_OPEN")" prot-marker 3 &
  r3=$!
  run "wt cross-read protected token reads open URL" "$WT" read "$(wt_url "$OPEN" "$T_PROT")" open-marker 3 &
  r4=$!
  wait $p1 $p2 $r1 $r2 $r3 $r4 || true
} >>"$LOGDIR/path-live.log" 2>&1

{
  note "native WebTransport refusals and announcements"
  run "wt encoded marker %7Eopen with open token" "$WT" refuse "$(wt_url "t/${OWNER}/%7Eopen/standup" "$T_OPEN")"
  run "wt double-encoded %257Eopen with open token" "$WT" refuse "$(wt_url "t/${OWNER}/%257Eopen/standup" "$T_OPEN")"
  run "wt literal tilde path is the open root (control admit via hold 1s)" "$WT" hold "$(wt_url "$OPEN" "$T_OPEN")" 1
  run "wt subscribe-only token cannot publish" "$WT" publish "$(wt_url "$OPEN" "$T_OPEN_SUB")" open-marker 2
  run "wt wide owner token hold on open URL (relay admits; edge must not)" "$WT" hold "$(wt_url "$OPEN" "$T_WIDE")" 1
  run "wt wide owner token hold on protected URL" "$WT" hold "$(wt_url "$PROT" "$T_WIDE")" 1
  "$WT" publish "$(wt_url "$OPEN" "$T_OPEN")" open-marker 4 >"$PRIV/ann-pub-open.out" 2>&1 &
  a1=$!
  "$WT" publish "$(wt_url "$PROT" "$T_PROT")" prot-marker 4 >"$PRIV/ann-pub-prot.out" 2>&1 &
  a2=$!
  sleep 1.2
  run "wt announce on open root" "$WT" announce "$(wt_url "$OPEN" "$T_OPEN_SUB")" 2
  run "wt announce on protected root" "$WT" announce "$(wt_url "$PROT" "$T_PROT_SUB")" 2
  wait_jobs "$a1" "$a2"
} >>"$LOGDIR/path-live.log" 2>&1

{
  note "Iroh (absolute paths)"
  run "iroh publish open-marker" "$IPUB" publish "$IROH" "$T_OPEN" "${OPEN}/open-marker" 4 &
  ip1=$!
  run "iroh publish prot-marker" "$IPUB" publish "$IROH" "$T_PROT" "${PROT}/prot-marker" 4 &
  ip2=$!
  sleep 1.2
  run "iroh own-read open" "$ISUB" read "$IROH" "$T_OPEN" "${OPEN}/open-marker" 3 &
  ir1=$!
  run "iroh own-read protected" "$ISUB" read "$IROH" "$T_PROT" "${PROT}/prot-marker" 3 &
  ir2=$!
  run "iroh cross-read open token on protected path" "$ISUB" read "$IROH" "$T_OPEN" "${PROT}/prot-marker" 3 &
  ir3=$!
  run "iroh cross-read protected token on open path" "$ISUB" read "$IROH" "$T_PROT" "${OPEN}/open-marker" 3 &
  ir4=$!
  wait $ip1 $ip2 $ir1 $ir2 $ir3 $ir4 || true
  "$IPUB" publish "$IROH" "$T_OPEN" "${OPEN}/open-marker" 4 >"$PRIV/iann-o.out" 2>&1 &
  ia1=$!
  "$IPUB" publish "$IROH" "$T_PROT" "${PROT}/prot-marker" 4 >"$PRIV/iann-p.out" 2>&1 &
  ia2=$!
  sleep 1.2
  run "iroh announce open token" "$ISUB" listen "$IROH" "$T_OPEN_SUB" 2
  run "iroh announce protected token" "$ISUB" listen "$IROH" "$T_PROT_SUB" 2
  run "iroh publish open token onto protected absolute path" "$IPUB" publish "$IROH" "$T_OPEN" "${PROT}/stolen" 2
  wait_jobs "$ia1" "$ia2"
} >>"$LOGDIR/path-live.log" 2>&1

# Chromium WebTransport. Localhost page is a secure context. Cert is trusted
# only via serverCertificateHashes of the harness leaf.
python3 - "$PRIV" "$PORT" "$HASH" "$OPEN" "$T_OPEN" "$OWNER" <<'PY' >"$PRIV/chromium.out" 2>&1 &
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
priv, port, digest, open_root, token, owner = sys.argv[1:]
page = r"""<!doctype html><meta charset=utf-8>
<script>
const q = new URLSearchParams(location.search);
function hexToBytes(h){const a=new Uint8Array(h.length/2);for(let i=0;i<h.length;i+=2)a[i/2]=parseInt(h.slice(i,i+2),16);return a;}
(async () => {
  const url = q.get("wt");
  let line;
  try {
    const wt = new WebTransport(url, {serverCertificateHashes:[{algorithm:"sha-256", value: hexToBytes(q.get("hash"))}]});
    await wt.ready;
    const stream = await wt.createUnidirectionalStream();
    const w = stream.getWriter();
    const payload = new TextEncoder().encode("chromium-open-marker");
    await w.write(payload);
    await w.close();
    line = "ready wrote="+payload.length+" urlpath="+new URL(url).pathname;
    try { await wt.close(); } catch (e) {}
  } catch (e) {
    line = "fail "+(e && (e.name+": "+e.message) || e);
  }
  await fetch("/log?k="+encodeURIComponent(q.get("k")), {method:"POST", body: line});
})();
</script>
"""
seen = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(page.encode())
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode()
        key = self.path.split("k=",1)[-1]
        seen[key] = body
        self.send_response(204); self.end_headers()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
print("page_port", srv.server_address[1])
open(priv+"/page.port","w").write(str(srv.server_address[1]))
import time
deadline = time.time()+25
while time.time()<deadline and len(seen)<3:
    time.sleep(0.2)
print(json.dumps(seen, indent=2))
srv.shutdown()
PY
PY_PID=$!
for _ in $(seq 1 40); do [[ -f "$PRIV/page.port" ]] && break; sleep 0.1; done
PAGE="$(cat "$PRIV/page.port" 2>/dev/null || true)"
if [[ -n "$PAGE" ]]; then
  UDATA="$(mktemp -d /tmp/path-chrome.XXXXXX)"
  enc_open="t/${OWNER}/%7Eopen/standup"
  dbl_open="t/${OWNER}/%257Eopen/standup"
  drive() {
    local key="$1" path="$2"
    local wt="https://127.0.0.1:${PORT}/${path}?jwt=${3}"
    "$CHROMIUM" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
      --user-data-dir="$UDATA/$key" \
      "http://127.0.0.1:${PAGE}/?k=${key}&hash=${HASH}&wt=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$wt")" \
      >"$PRIV/chrome-$key.err" 2>&1 &
  }
  drive literal "$OPEN" "$T_OPEN"
  drive encoded "$enc_open" "$T_OPEN"
  drive double "$dbl_open" "$T_OPEN"
  wait "$PY_PID" || true
  pkill -f "user-data-dir=$UDATA" 2>/dev/null || true
  sleep 0.3
  rm -rf "$UDATA"
else
  wait "$PY_PID" || true
fi
{
  note "Chromium WebTransport (headless, serverCertificateHashes, unidirectional write)"
  echo "chromium=$($CHROMIUM --version 2>/dev/null | head -1)"
  if [[ -f "$PRIV/chromium.out" ]]; then cat "$PRIV/chromium.out"; else echo "chromium driver did not start"; fi
  echo
  echo "### chrome stderr tails"
  for f in "$PRIV"/chrome-*.err; do
    [[ -f "$f" ]] || continue
    echo "-- $(basename "$f")"
    tail -c 400 "$f" | redact
    echo
  done
} >>"$LOGDIR/path-live.log"

echo "LOG $LOGDIR/path-live.log"
