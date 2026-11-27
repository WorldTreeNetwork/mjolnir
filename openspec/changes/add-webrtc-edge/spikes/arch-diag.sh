#!/bin/bash
# Arch diagnostic harness for the fixed local edge. Not a product change.
# Records requester-vs-publisher expiry, early vs late playback, dial timeout,
# and HTTP cancellation. Tokens stay under $P and are redacted on the way out.
set -u
P=/tmp/mj13-diag
BIN=/tmp/mj13-tgt/release
EV=$P/evidence
EDGE_SHA=a8e6b9b7b6b7bdf75c7963e9fee6565e0271a79cc91fde778b9403a8cff8d055
RELAY_SHA=812c76ed185d4f3216e1f735b4cf2e07daf129fffe1512cfda928cf3ba2782b9
rm -rf "$P"
mkdir -p "$P/pages" "$P/tls" "$P/mint" "$P/state" "$EV"
cp /tmp/mj13/openspec/changes/add-webrtc-edge/spikes/pages/* "$P/pages/"
cp /tmp/mj13/openspec/changes/add-webrtc-edge/spikes/drive.mjs "$P/drive.mjs"
redact() { sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[jwt]/g'; }
now() { date +%s.%N; }
exp_of() { python3 -c 'import json,sys,base64; t=open(sys.argv[1]).read().strip().split(".")[1]; t+="="*((4-len(t)%4)%4); print(json.loads(base64.urlsafe_b64decode(t))["exp"])' "$1"; }

echo "platform $(uname -s) $(uname -m) $(. /etc/os-release && echo "$ID $VERSION_ID")" | tee "$EV/platform.txt"
sha256sum "$BIN/mjolnir-edge" "$BIN/mjolnir-relay" | tee "$EV/bin-sha256.txt"
grep -q "$EDGE_SHA" "$EV/bin-sha256.txt" || { echo "edge hash is not the current binary"; exit 2; }
grep -q "$RELAY_SHA" "$EV/bin-sha256.txt" || { echo "relay hash mismatch"; exit 2; }
echo Arch > "$EV/distro-label.txt"

ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0xC83278:s=640x720:r=30" \
  -f lavfi -i "color=c=0x1EA0A0:s=640x720:r=30" \
  -filter_complex "[0][1]hstack,format=yuv420p,drawbox=x='mod(t*40,600)':y=80:w=8:h=560:color=0xB4466E" \
  -t 40 "$P/move.y4m"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 40 -ac 1 "$P/move.wav"
python3 - <<PY | tee "$EV/source-geometry.txt"
import pathlib
b = pathlib.Path("$P/move.y4m").read_bytes().split(b"\n", 1)[0].decode()
print(b)
PY

openssl req -x509 -newkey ed25519 -keyout "$P/tls/key.pem" -out "$P/tls/cert.pem" -days 2 -nodes \
  -subj /CN=localhost \
  -addext basicConstraints=critical,CA:FALSE \
  -addext extendedKeyUsage=serverAuth \
  -addext keyUsage=digitalSignature \
  -addext subjectAltName=DNS:localhost >/dev/null 2>&1

chmod 700 "$P/mint"
"$BIN/mjolnir-relay" --write-mint-key "$P/mint/current.jwk" edgeProof1 > "$P/mint/public.json"
chmod 600 "$P/mint/current.jwk"
sudo rm -rf /var/tmp/mj13-keys
sudo mkdir -m 755 /var/tmp/mj13-keys
sudo cp "$P/mint/public.json" /var/tmp/mj13-keys/relay-keys.json
sudo chown root:root /var/tmp/mj13-keys /var/tmp/mj13-keys/relay-keys.json
sudo chmod 755 /var/tmp/mj13-keys
sudo chmod 644 /var/tmp/mj13-keys/relay-keys.json

cat > "$P/relay.env" <<EOF
MJOLNIR_RELAY_ENABLED=true
MJOLNIR_RELAY_HOST=localhost
MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
EOF
SUB=$(python3 -c 'print("09"*32)')
cat > "$P/mint.exs" <<'EXS'
owner = System.fetch_env!("MINT_SUB")
key = System.fetch_env!("MINT_KEY")
env = System.fetch_env!("MINT_ENV")
out = System.fetch_env!("MINT_OUT")
caller = %{kind: :user, scopes: "relay:join", sub: owner}
opts = [key_path: key, env_path: env, uid: 1000]
mint = fn participant, ttl ->
  case Mjolnir.Relay.Mint.issue(caller, "r1", participant, %{"kind" => "open", "ttl" => ttl}, opts) do
    {:ok, minted} ->
      File.write!(Path.join(out, participant <> ".tok"), minted.token)
      File.write!(Path.join(out, participant <> ".meta"), "#{minted.root}\n#{minted.expires}\n")
      IO.puts("minted #{participant} exp=#{minted.expires}")
    other ->
      IO.inspect(other)
      System.halt(1)
  end
end
mint.("alice", 600)
mint.("bob", 600)
mint.("short", 12)
mint.("brief", 8)
EXS
cd /home/dorje/work/IdentiKey/mjolnir
PATH="$HOME/.local/share/mise/shims:$PATH" \
  MINT_SUB="$SUB" MINT_KEY="$P/mint/current.jwk" MINT_ENV="$P/relay.env" MINT_OUT="$P" \
  MIX_ENV=test mix run --no-start --no-deps-check "$P/mint.exs" >"$EV/mix.txt" 2>&1 || {
    # The earlier proof wrote the key. Reuse it if this run has no key yet.
    if [ ! -f "$P/mint/current.jwk" ] && [ -f /tmp/mj13-run/mint/current.jwk ]; then
      cp -a /tmp/mj13-run/mint/current.jwk "$P/mint/current.jwk" || true
    fi
  }
if [ ! -s "$P/alice.tok" ]; then
  if [ ! -f "$P/mint/current.jwk" ]; then
    echo "no mint key"; exit 2
  fi
  PATH="$HOME/.local/share/mise/shims:$PATH" \
    MINT_SUB="$SUB" MINT_KEY="$P/mint/current.jwk" MINT_ENV="$P/relay.env" MINT_OUT="$P" \
    MIX_ENV=test mix run --no-start --no-deps-check "$P/mint.exs" >"$EV/mix.txt" 2>&1
fi
echo MIX:$(wc -c < "$P/alice.tok") | tee "$EV/mix-status.txt"
ROOT=$(head -1 "$P/alice.meta")
cp "$P/alice.tok" "$P/move.tok"
echo "alice_exp $(exp_of "$P/alice.tok")" | tee "$EV/token-exp.txt"
echo "bob_exp $(exp_of "$P/bob.tok")" | tee -a "$EV/token-exp.txt"
echo "short_exp $(exp_of "$P/short.tok")" | tee -a "$EV/token-exp.txt"
echo "brief_exp $(exp_of "$P/brief.tok")" | tee -a "$EV/token-exp.txt"

export MJOLNIR_RELAY_HOST=localhost
export MJOLNIR_RELAY_BIND=127.0.0.1:9443
export MJOLNIR_RELAY_TLS_DIR=$P/tls
export MJOLNIR_RELAY_KEYS=/var/tmp/mj13-keys/relay-keys.json
export MJOLNIR_RELAY_KEYS_ACTIVE=$P/keys.active
export MJOLNIR_RELAY_STATE_DIR=$P/state
export MJOLNIR_RELAY_LOCATOR=$P/locator.json
export MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
"$BIN/mjolnir-relay" >"$EV/relay.log" 2>&1 &
RELAY_PID=$!
export MJOLNIR_EDGE_KEYS=/var/tmp/mj13-keys/relay-keys.json
export MJOLNIR_EDGE_RELAY=https://localhost:9443
export MJOLNIR_EDGE_TLS_ROOT=$P/tls/cert.pem
export MJOLNIR_EDGE_BIND=127.0.0.1:8444
export MJOLNIR_EDGE_MEDIA=127.0.0.1:0
"$BIN/mjolnir-edge" >"$EV/edge.log" 2>&1 &
EDGE_PID=$!
python3 -m http.server 18125 --bind 127.0.0.1 --directory "$P/pages" >"$EV/pages.log" 2>&1 &
PAGES_PID=$!
cleanup() { kill $RELAY_PID $EDGE_PID $PAGES_PID $BH_PID 2>/dev/null || true; }
BH_PID=
trap cleanup EXIT
for i in $(seq 1 50); do
  grep -q "listening" "$EV/edge.log" && grep -q "iroh endpoint" "$EV/relay.log" && break
  sleep 0.2
done

AUTH="Authorization: Bearer $(cat "$P/alice.tok")"
ss -u -n > "$EV/ss-before-admit.txt" || true
curl -sS -D "$EV/admit.headers" -o "$EV/admit.body" \
  -H "$AUTH" -H "x-mjolnir-root: $ROOT" -H 'content-type: application/json' \
  -d '{"operation":"publish","broadcast":"alice/cam"}' \
  http://127.0.0.1:8444/admit || true
ss -u -n > "$EV/ss-after-admit.txt" || true
echo "udp sockets before $(wc -l < "$EV/ss-before-admit.txt") after $(wc -l < "$EV/ss-after-admit.txt")" | tee "$EV/admit-sockets.txt"
redact < "$EV/admit.body" > "$EV/admit-body.txt"

ln -sfn /tmp/kf-pw/node_modules "$P/node_modules"
cd "$P"
export P EDGE=http://127.0.0.1:8444 PAGES=http://127.0.0.1:18125
export CHROMIUM_BIN=/usr/bin/chromium EDGE_ROOT="$ROOT" NODE_PATH=/tmp/kf-pw/node_modules

sessions() { grep -c "session accepted" "$EV/relay.log" || true; }

# Early join on the current binary.
node "$P/drive.mjs" pub move alice/cam - 14 move >"$EV/early-pub.json" 2>"$EV/early-pub.err" &
EPUB=$!
sleep 2
node "$P/drive.mjs" play chromium alice/cam - 6 0xC83278 0x1EA0A0 440 bob >"$EV/early-play.json" 2>"$EV/early-play.err" || true
echo EARLY_PLAY:$? | tee "$EV/early-play-exit.txt"
wait $EPUB || true

# Late join, same source, playback starts at 8s.
node "$P/drive.mjs" pub move alice/cam - 16 move >"$EV/late-pub.json" 2>"$EV/late-pub.err" &
LPUB=$!
sleep 8
node "$P/drive.mjs" play chromium alice/cam - 6 0xC83278 0x1EA0A0 440 bob >"$EV/late-play.json" 2>"$EV/late-play.err" || true
echo LATE_PLAY:$? | tee "$EV/late-play-exit.txt"
wait $LPUB || true

python3 - <<'PY' | tee "$EV/playback-summary.txt"
import json
def load(path):
    rows=[]
    for line in open(path):
        line=line.strip()
        if line.startswith("{"):
            rows.append(json.loads(line))
    return rows
for name in ("early","late"):
    play=load(f"/tmp/mj13-diag/evidence/{name}-play.json")
    result=next(r for r in play if r.get("step")=="result" or r.get("error") or r.get("step")=="play")
    content=(result.get("content") or {})
    last=(result.get("last") or {}).get("videoIn") or {}
    print(name,
          "exit_step", result.get("step"),
          "video", last.get("frameWidth"), last.get("frameHeight"),
          "frames", last.get("framesDecoded"),
          "videoMatch", content.get("videoMatch"),
          "audioMatch", content.get("audioMatch"),
          "peakHz", content.get("audioPeakHz"),
          "rms", content.get("audioRms"),
          "error", result.get("error"))
PY

# Publisher with the 12s token. Viewer bob is still valid. Then the expired publisher token itself.
SHORT_EXP=$(exp_of "$P/short.tok")
echo "short_phase_start $(now) short_exp $SHORT_EXP" | tee "$EV/expiry-clock.txt"
node "$P/drive.mjs" pub move short/cam - 20 short >"$EV/short-pub.json" 2>"$EV/short-pub.err" &
SPUB=$!
sleep 2
node "$P/drive.mjs" play chromium short/cam - 4 0xC83278 0x1EA0A0 440 bob >"$EV/short-live.json" 2>"$EV/short-live.err" || true
echo SHORT_LIVE:$? | tee -a "$EV/expiry-clock.txt"
# Wait until the publisher token is past exp.
python3 - <<PY
import time
exp=float("$SHORT_EXP")
delay=exp-time.time()+1.5
print("sleep_until_after_short_exp", delay)
if delay>0: time.sleep(delay)
PY
echo "after_short_exp $(now)" | tee -a "$EV/expiry-clock.txt"
BEFORE=$(sessions)
# Valid viewer, publisher already expired: catalog miss, not an expired requester.
node "$P/drive.mjs" play chromium short/cam - 3 0xC83278 0x1EA0A0 440 bob >"$EV/viewer-after-publisher-exp.json" 2>"$EV/viewer-after.err" || true
echo VIEWER_AFTER:$? sessions_delta $(( $(sessions) - BEFORE )) | tee -a "$EV/expiry-clock.txt"
# Expired requester. Admission is before SDP, so a dummy body still shows the status.
BEFORE=$(sessions)
EXP_REQ_START=$(now)
code=$(curl -sS -o "$EV/expired-requester.body" -w '%{http_code}' -X POST \
  -H "authorization: Bearer $(cat "$P/short.tok")" \
  -H "x-mjolnir-root: $ROOT" \
  -H 'content-type: application/sdp' \
  --data 'v=0' \
  "http://127.0.0.1:8444/whep/r1/short/cam" || true)
echo "expired_requester start $EXP_REQ_START end $(now) http $code sessions_delta $(( $(sessions) - BEFORE ))" | tee -a "$EV/expiry-clock.txt"
redact < "$EV/expired-requester.body" >> "$EV/expiry-clock.txt"
wait $SPUB || true

# Dial timeout and cancellation against a relay port with nothing bound.
export MJOLNIR_EDGE_RELAY=https://127.0.0.1:9444
export MJOLNIR_EDGE_BIND=127.0.0.1:8445
export MJOLNIR_EDGE_MEDIA=127.0.0.1:0
"$BIN/mjolnir-edge" >"$EV/blackhole-edge.log" 2>&1 &
BH_PID=$!
for i in $(seq 1 50); do grep -q "listening" "$EV/blackhole-edge.log" && break; sleep 0.1; done
post_bh() {
  local out=$1 max=$2
  local start=$(now)
  local code
  code=$(curl -sS -m "$max" -o "$EV/$out.body" -w '%{http_code}' -X POST \
    -H "authorization: Bearer $(cat "$P/alice.tok")" \
    -H "x-mjolnir-root: $ROOT" \
    -H 'content-type: application/sdp' \
    --data 'v=0' \
    "http://127.0.0.1:8445/whip/r1/alice/cam" || echo curl_$?)
  echo "$out start $start end $(now) http $code" | tee -a "$EV/timeout.txt"
  redact < "$EV/$out.body" >> "$EV/timeout.txt" || true
}
echo "timeout_single" | tee "$EV/timeout.txt"
post_bh timeout-a 8
echo "cancel_then_second" | tee -a "$EV/timeout.txt"
curl -sS -m 1 -o "$EV/cancel.body" -w '%{http_code}' -X POST \
  -H "authorization: Bearer $(cat "$P/alice.tok")" \
  -H "x-mjolnir-root: $ROOT" \
  -H 'content-type: application/sdp' \
  --data 'v=0' \
  "http://127.0.0.1:8445/whip/r1/alice/side" >"$EV/cancel.code" 2>"$EV/cancel.err" &
C=$!
sleep 0.2
SECOND_START=$(now)
post_bh after-cancel 8 &
P2=$!
wait $C || true
echo "cancel_finished $(now) code $(cat "$EV/cancel.code" 2>/dev/null) err $(tail -1 "$EV/cancel.err" 2>/dev/null)" | tee -a "$EV/timeout.txt"
wait $P2 || true
echo "after_cancel_was_started $SECOND_START" | tee -a "$EV/timeout.txt"
echo "two_concurrent" | tee -a "$EV/timeout.txt"
post_bh conc-a 8 &
CA=$!
post_bh conc-b 8 &
CB=$!
wait $CA $CB || true

echo "--- pool lines ---" | tee "$EV/pool-lines.txt"
grep -E "pool after delete|expired token dropped" "$EV/edge.log" | tee -a "$EV/pool-lines.txt" || true
echo "--- eviction ---" | tee "$EV/eviction.txt"
grep -E "evicted|opus|authorization token expired|negotiation failed" "$EV/edge.log" | tee -a "$EV/eviction.txt" || true
redact < "$EV/early-play.json" > "$EV/early-play.redacted.json" || true
redact < "$EV/late-play.json" > "$EV/late-play.redacted.json" || true
redact < "$EV/short-live.json" > "$EV/short-live.redacted.json" || true
redact < "$EV/viewer-after-publisher-exp.json" > "$EV/viewer-after.redacted.json" || true
echo DIAG_DONE
