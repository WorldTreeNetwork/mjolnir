#!/bin/bash
# Real Mint.issue tokens. Publishers stay up for the whole negative window.
# Disposable relay only. Tokens are redacted in the log.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
LOGDIR="${1:?log dir}"
mkdir -p "$LOGDIR"
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
PAIR="$ROOT/native/mjolnir_relay/target/debug/iroh-pair"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
CHROMIUM="${CHROMIUM:-/Users/dukejones/Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"
HOLD=130
PRIV="$(mktemp -d /tmp/mint-sustained.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.3; pkill -P $$ >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [[ -f /tmp/moq-src/net/package.json ]]; then
  cp "$ROOT/openspec/changes/add-open-room-kind/spikes/path/moq-sub.ts" /tmp/moq-src/net/moq-sub.ts
  (cd /tmp/moq-src/net && bun build moq-sub.ts --target=browser --outfile=/tmp/moq-sub.js)
fi
"$SPIKE" relay "$PRIV" >"$PRIV/relay.out" 2>&1 &
for _ in $(seq 1 80); do
  [[ -f "$PRIV/relay.txt" && -f "$PRIV/private.json" && -f "$PRIV/iroh.txt" && -f "$PRIV/hash.txt" ]] && break
  sleep 0.25
done
[[ -f "$PRIV/iroh.txt" ]] || { echo RELAY_FAIL | tee "$LOGDIR/path-mint-sustained.log"; cat "$PRIV/relay.out"; exit 1; }
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); json.dump(p["keys"][0], open(sys.argv[2],"w"))' "$PRIV/private.json" "$PRIV/current.jwk"
chmod 600 "$PRIV/current.jwk"; chmod 700 "$PRIV"
printf 'MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=127.0.0.1\nMJOLNIR_RELAY_TOKEN_MAX_TTL=3600\n' >"$PRIV/relay.env"
cd "$ROOT"
UIDN=$(stat -f %u "$PRIV/current.jwk")
OUT="$PRIV/tok"; mkdir -p "$OUT"
MIX_ENV=test KEY="$PRIV/current.jwk" ENVF="$PRIV/relay.env" UIDN="$UIDN" OUT="$OUT" mix run --no-start -e '
owner = Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
opts = [key_path: System.fetch_env!("KEY"), env_path: System.fetch_env!("ENVF"), uid: String.to_integer(System.fetch_env!("UIDN"))]
caller = %{kind: :user, sub: owner, scopes: "relay:join"}
out = System.fetch_env!("OUT")
Enum.each([{"open-alice","open","alice"},{"open-bob","open","bob"},{"prot-alice","protected","alice"}], fn {name, kind, part} ->
  {:ok, minted} = Mjolnir.Relay.Mint.issue(caller, "standup", part, %{"kind" => kind}, opts)
  File.write!(Path.join(out, name), minted.token)
  IO.puts("minted #{name} kind=#{minted.kind} publish=#{minted.publish}")
end)
' >"$PRIV/mint.out"
claim() { python3 -c 'import base64,json,sys; raw=open(sys.argv[1]).read().strip().split(".")[1]; raw+="="*(-len(raw)%4); print(json.loads(base64.urlsafe_b64decode(raw))["root"])' "$1"; }
OA=$(cat "$OUT/open-alice"); OB=$(cat "$OUT/open-bob"); PA=$(cat "$OUT/prot-alice")
OPEN=$(claim "$OUT/open-alice"); PROT=$(claim "$OUT/prot-alice")
ADDR=$(cat "$PRIV/relay.txt"); IROH=$(cat "$PRIV/iroh.txt"); HASH=$(cat "$PRIV/hash.txt"); PORT=${ADDR##*:}
redact() { sed -E 's/jwt=[^& ]+/jwt=REDACTED/g; s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g'; }
run() { echo; echo "### $1"; shift; python3 - "$@" <<'PY' | redact
import subprocess, sys
cmd=sys.argv[1:]
try:
    p=subprocess.run(cmd, capture_output=True, text=True, timeout=16)
    sys.stdout.write(p.stdout); sys.stdout.write(p.stderr); print(f"exit={p.returncode}")
except subprocess.TimeoutExpired as e:
    out=e.stdout or ""; err=e.stderr or ""
    if isinstance(out, bytes):
        out=out.decode(errors="replace"); err=err.decode(errors="replace")
    sys.stdout.write(out); sys.stdout.write(err); print("killed-after-16s"); print("exit=124")
PY
}
wt_url() { python3 -c 'import urllib.parse,sys; print("https://127.0.0.1:%s/%s?jwt=%s"%(sys.argv[1], sys.argv[2], urllib.parse.quote(sys.argv[3], safe="")))' "$PORT" "$1" "$2"; }
alive() { if kill -0 "$1" 2>/dev/null; then echo alive; else echo dead; fi; }

"$PAIR" publish "$IROH" "$OA" "${OPEN}/alice/marker" $HOLD "$PRIV/ready-oa" "MINT-OPEN" >"$PRIV/pub-oa.out" 2>&1 &
POA=$!
"$PAIR" publish "$IROH" "$OB" "${OPEN}/bob/marker" $HOLD "$PRIV/ready-ob" "MINT-BOB" >"$PRIV/pub-ob.out" 2>&1 &
POB=$!
"$PAIR" publish "$IROH" "$PA" "${PROT}/alice/marker" $HOLD "$PRIV/ready-pa" "MINT-PROT" >"$PRIV/pub-pa.out" 2>&1 &
PPA=$!
for f in ready-oa ready-ob ready-pa; do
  for _ in $(seq 1 80); do [[ -f $PRIV/$f ]] && break; sleep 0.1; done
done
"$WT" publish "$(wt_url "$OPEN" "$OA")" "alice/marker" $HOLD >"$PRIV/wt-oa.out" 2>&1 &
WTOA=$!
"$WT" publish "$(wt_url "$OPEN" "$OB")" "bob/marker" $HOLD >"$PRIV/wt-ob.out" 2>&1 &
WTOB=$!
"$WT" publish "$(wt_url "$PROT" "$PA")" "alice/marker" $HOLD >"$PRIV/wt-pa.out" 2>&1 &
WTPA=$!
sleep 1.2

{
  echo "# sustained mint evidence $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "quic=$ADDR iroh=$IROH cert_sha256=$HASH hold=${HOLD}s"
  echo "open_root=$OPEN"
  echo "protected_root=$PROT"
  cat "$PRIV/mint.out" | redact
  echo "ready oa=$([[ -f $PRIV/ready-oa ]] && echo yes || echo no) ob=$([[ -f $PRIV/ready-ob ]] && echo yes || echo no) pa=$([[ -f $PRIV/ready-pa ]] && echo yes || echo no)"
  echo "publishers-before iroh=$(alive $POA)/$(alive $POB)/$(alive $PPA) wt=$(alive $WTOA)/$(alive $WTOB)/$(alive $WTPA)"
  run "iroh before open-alice" "$PAIR" read "$IROH" "$OA" "${OPEN}/alice/marker" 6 2
  run "iroh before open-bob" "$PAIR" read "$IROH" "$OB" "${OPEN}/bob/marker" 6 2
  run "iroh before protected-alice" "$PAIR" read "$IROH" "$PA" "${PROT}/alice/marker" 6 2
  run "iroh cross open token on protected path" "$PAIR" read "$IROH" "$OA" "${PROT}/alice/marker" 6 2
  run "iroh cross protected token on open path" "$PAIR" read "$IROH" "$PA" "${OPEN}/alice/marker" 6 2
  run "iroh alice token on bob path" "$PAIR" read "$IROH" "$OA" "${OPEN}/bob/marker" 6 2
  echo "publishers-after-iroh-negatives iroh=$(alive $POA)/$(alive $POB)/$(alive $PPA)"
  run "iroh after open-alice" "$PAIR" read "$IROH" "$OA" "${OPEN}/alice/marker" 6 2
  run "iroh after open-bob" "$PAIR" read "$IROH" "$OB" "${OPEN}/bob/marker" 6 2
  run "iroh after protected-alice" "$PAIR" read "$IROH" "$PA" "${PROT}/alice/marker" 6 2
  run "iroh listen open-alice 4s" "$PAIR" listen "$IROH" "$OA" 4
  run "wt before alice" "$WT" read "$(wt_url "$OPEN" "$OA")" "alice/marker" 2
  run "wt before bob" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/marker" 2
  run "wt before protected" "$WT" read "$(wt_url "$PROT" "$PA")" "alice/marker" 2
  run "wt cross open token protected url" "$WT" read "$(wt_url "$PROT" "$OA")" "alice/marker" 2
  run "wt alice publish on bob path" "$WT" publish "$(wt_url "$OPEN" "$OA")" "bob/marker" 3
  echo "publishers-after-wt-negatives wt=$(alive $WTOA)/$(alive $WTOB)/$(alive $WTPA) iroh=$(alive $POA)/$(alive $POB)/$(alive $PPA)"
  run "wt after alice" "$WT" read "$(wt_url "$OPEN" "$OA")" "alice/marker" 2
  run "wt after bob" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/marker" 2
  run "wt after protected" "$WT" read "$(wt_url "$PROT" "$PA")" "alice/marker" 2
  run "wt alice reads bob sibling" "$WT" read "$(wt_url "$OPEN" "$OA")" "bob/marker" 2
  run "wt bob reads alice sibling" "$WT" read "$(wt_url "$OPEN" "$OB")" "alice/marker" 2
  if [[ -f /tmp/moq-sub.js && -x "$CHROMIUM" ]]; then
    python3 - "$PRIV" "$PORT" "$HASH" "$OPEN" "$OA" <<'PY' &
import json,sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
priv,port,digest,root,token=sys.argv[1:]
js=open("/tmp/moq-sub.js",encoding="utf-8").read()
def page(url):
    cfg=json.dumps({"url":url,"hash":digest,"path":"alice/marker","seconds":4})
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
    echo "chromium-publisher-before=$(alive $WTOA)"
    for name in literal encoded double; do
      "$CHROMIUM" --headless=new --disable-gpu --no-first-run --user-data-dir="$PRIV/c-$name" "http://127.0.0.1:${PP}/$name" >/dev/null 2>"$PRIV/e-$name" &
      cp=$!
      for _ in $(seq 1 70); do
        grep -q -E 'received path=|moq-error' "$PRIV/log-$name.txt" 2>/dev/null && break
        sleep 0.25
      done
      kill $cp 2>/dev/null || true
      wait $cp 2>/dev/null || true
      echo "## chromium $name"
      if [[ -f $PRIV/log-$name.txt ]]; then redact <"$PRIV/log-$name.txt"; else echo missing; fi
    done
    echo "chromium-publisher-after=$(alive $WTOA)"
  else
    echo "browser-skipped bundle=$([[ -f /tmp/moq-sub.js ]] && echo yes || echo no)"
  fi
  echo "publishers-final iroh=$(alive $POA)/$(alive $POB)/$(alive $PPA) wt=$(alive $WTOA)/$(alive $WTOB)/$(alive $WTPA)"
  echo "--- iroh publisher tails ---"
  redact <"$PRIV/pub-oa.out" | tail -5
  redact <"$PRIV/pub-ob.out" | tail -5
  redact <"$PRIV/pub-pa.out" | tail -5
} | redact >"$LOGDIR/path-mint-sustained.log"
echo wrote "$LOGDIR/path-mint-sustained.log"
