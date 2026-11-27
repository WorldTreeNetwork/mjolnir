#!/bin/bash
# Same Arch binary as arch-diag.sh. Mints the short token immediately before publish
# so a live broadcast exists, then separates an expired requester from a valid viewer.
set -u
P=/tmp/mj13-exp
BIN=/tmp/mj13-tgt/release
EV=$P/evidence
EDGE_SHA=a8e6b9b7b6b7bdf75c7963e9fee6565e0271a79cc91fde778b9403a8cff8d055
rm -rf "$P"
mkdir -p "$P/pages" "$P/tls" "$P/mint" "$P/state" "$EV"
cp /tmp/mj13/openspec/changes/add-webrtc-edge/spikes/pages/* "$P/pages/"
cp /tmp/mj13/openspec/changes/add-webrtc-edge/spikes/drive.mjs "$P/drive.mjs"
redact() { sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[jwt]/g'; }
now() { date +%s.%N; }
exp_of() { python3 -c 'import json,sys,base64; t=open(sys.argv[1]).read().strip().split(".")[1]; t+="="*((4-len(t)%4)%4); print(json.loads(base64.urlsafe_b64decode(t))["exp"])' "$1"; }
sha256sum "$BIN/mjolnir-edge" | tee "$EV/bin-sha256.txt"
grep -q "$EDGE_SHA" "$EV/bin-sha256.txt" || exit 2
ffmpeg -y -loglevel error -f lavfi -i "color=c=0xC83278:s=640x720:r=30" -f lavfi -i "color=c=0x1EA0A0:s=640x720:r=30" \
  -filter_complex "[0][1]hstack,format=yuv420p" -t 30 "$P/move.y4m"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 30 -ac 1 "$P/move.wav"
openssl req -x509 -newkey ed25519 -keyout "$P/tls/key.pem" -out "$P/tls/cert.pem" -days 2 -nodes \
  -subj /CN=localhost -addext basicConstraints=critical,CA:FALSE \
  -addext extendedKeyUsage=serverAuth -addext keyUsage=digitalSignature \
  -addext subjectAltName=DNS:localhost >/dev/null 2>&1
chmod 700 "$P/mint"
"$BIN/mjolnir-relay" --write-mint-key "$P/mint/current.jwk" edgeProofExp > "$P/mint/public.json"
chmod 600 "$P/mint/current.jwk"
sudo rm -rf /var/tmp/mj13-keys
sudo mkdir -m 755 /var/tmp/mj13-keys
sudo cp "$P/mint/public.json" /var/tmp/mj13-keys/relay-keys.json
sudo chown root:root /var/tmp/mj13-keys /var/tmp/mj13-keys/relay-keys.json
sudo chmod 755 /var/tmp/mj13-keys && sudo chmod 644 /var/tmp/mj13-keys/relay-keys.json
cat > "$P/relay.env" <<'EOF'
MJOLNIR_RELAY_ENABLED=true
MJOLNIR_RELAY_HOST=localhost
MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
EOF
SUB=$(python3 -c 'print("09"*32)')
cat > "$P/mint-long.exs" <<'EXS'
owner = System.fetch_env!("MINT_SUB")
key = System.fetch_env!("MINT_KEY")
env = System.fetch_env!("MINT_ENV")
out = System.fetch_env!("MINT_OUT")
caller = %{kind: :user, scopes: "relay:join", sub: owner}
opts = [key_path: key, env_path: env, uid: 1000]
for {participant, ttl} <- [{"alice", 600}, {"bob", 600}] do
  {:ok, minted} = Mjolnir.Relay.Mint.issue(caller, "r1", participant, %{"kind" => "open", "ttl" => ttl}, opts)
  File.write!(Path.join(out, participant <> ".tok"), minted.token)
  File.write!(Path.join(out, participant <> ".meta"), minted.root)
end
EXS
cd /home/dorje/work/IdentiKey/mjolnir
PATH="$HOME/.local/share/mise/shims:$PATH" \
  MINT_SUB="$SUB" MINT_KEY="$P/mint/current.jwk" MINT_ENV="$P/relay.env" MINT_OUT="$P" \
  MIX_ENV=test mix run --no-start --no-deps-check "$P/mint-long.exs" >"$EV/mix-long.txt" 2>&1
ROOT=$(cat "$P/alice.meta")
cp "$P/alice.tok" "$P/move.tok"
export MJOLNIR_RELAY_HOST=localhost MJOLNIR_RELAY_BIND=127.0.0.1:9443
export MJOLNIR_RELAY_TLS_DIR=$P/tls
export MJOLNIR_RELAY_KEYS=/var/tmp/mj13-keys/relay-keys.json
export MJOLNIR_RELAY_KEYS_ACTIVE=$P/keys.active
export MJOLNIR_RELAY_STATE_DIR=$P/state MJOLNIR_RELAY_LOCATOR=$P/locator.json
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
cleanup() { kill $RELAY_PID $EDGE_PID $PAGES_PID 2>/dev/null || true; }
trap cleanup EXIT
for i in $(seq 1 50); do grep -q "listening" "$EV/edge.log" && grep -q "iroh endpoint" "$EV/relay.log" && break; sleep 0.2; done
ln -sfn /tmp/kf-pw/node_modules "$P/node_modules"
cd "$P"
export P EDGE=http://127.0.0.1:8444 PAGES=http://127.0.0.1:18125
export CHROMIUM_BIN=/usr/bin/chromium EDGE_ROOT="$ROOT" NODE_PATH=/tmp/kf-pw/node_modules
sessions() { grep -c "session accepted" "$EV/relay.log" || true; }

# Mint the publisher token now, ttl 15s, then publish before it ages out.
cat > "$P/mint-short.exs" <<'EXS'
owner = System.fetch_env!("MINT_SUB")
key = System.fetch_env!("MINT_KEY")
env = System.fetch_env!("MINT_ENV")
out = System.fetch_env!("MINT_OUT")
caller = %{kind: :user, scopes: "relay:join", sub: owner}
opts = [key_path: key, env_path: env, uid: 1000]
{:ok, minted} = Mjolnir.Relay.Mint.issue(caller, "r1", "short", %{"kind" => "open", "ttl" => 15}, opts)
File.write!(Path.join(out, "short.tok"), minted.token)
IO.puts(minted.expires)
EXS
cd /home/dorje/work/IdentiKey/mjolnir
PATH="$HOME/.local/share/mise/shims:$PATH" \
  MINT_SUB="$SUB" MINT_KEY="$P/mint/current.jwk" MINT_ENV="$P/relay.env" MINT_OUT="$P" \
  MIX_ENV=test mix run --no-start --no-deps-check "$P/mint-short.exs" >"$EV/mix-short.txt" 2>&1
SHORT_EXP=$(exp_of "$P/short.tok")
echo "minted_short $(now) exp $SHORT_EXP" | tee "$EV/clock.txt"
cd "$P"
node "$P/drive.mjs" pub move short/cam - 25 short >"$EV/pub.json" 2>"$EV/pub.err" &
SPUB=$!
sleep 2
node "$P/drive.mjs" play chromium short/cam - 4 0xC83278 0x1EA0A0 440 bob >"$EV/live.json" 2>"$EV/live.err"
echo LIVE_EXIT:$? | tee -a "$EV/clock.txt" || true
python3 - <<PY
import time
exp=float("$SHORT_EXP")
delay=exp - time.time() + 2
print("wait", delay)
if delay > 0: time.sleep(delay)
PY
echo "past_exp $(now) exp $SHORT_EXP" | tee -a "$EV/clock.txt"
BEFORE=$(sessions)
node "$P/drive.mjs" play chromium short/cam - 3 0xC83278 0x1EA0A0 440 bob >"$EV/viewer.json" 2>"$EV/viewer.err"
echo VIEWER_EXIT:$? sessions_delta:$(( $(sessions) - BEFORE )) | tee -a "$EV/clock.txt" || true
BEFORE=$(sessions)
code=$(curl -sS -o "$EV/requester.body" -w '%{http_code}' -X POST \
  -H "authorization: Bearer $(cat "$P/short.tok")" \
  -H "x-mjolnir-root: $ROOT" -H 'content-type: application/sdp' --data 'v=0' \
  "http://127.0.0.1:8444/whep/r1/short/cam" || true)
echo "expired_publisher_token_as_requester http $code at $(now) sessions_delta $(( $(sessions) - BEFORE ))" | tee -a "$EV/clock.txt"
redact < "$EV/requester.body" >> "$EV/clock.txt"
# A still-valid alice session, then DELETE, for the pool log.
node "$P/drive.mjs" pub move alice/cam - 12 move >"$EV/alice-pub.json" 2>"$EV/alice.err" &
AP=$!
LOC=
for i in $(seq 1 40); do
  LOC=$(python3 -c 'import json
try:
  print(json.loads(open("/tmp/mj13-exp/evidence/alice-pub.json").readline()).get("location",""))
except Exception:
  print("")' 2>/dev/null || true)
  [ -n "$LOC" ] && break
  sleep 0.25
done
echo "delete_target $LOC" | tee -a "$EV/clock.txt"
code=$(curl -sS -o "$EV/del.body" -w '%{http_code}' -X DELETE -H "authorization: Bearer $(cat "$P/alice.tok")" "http://127.0.0.1:8444$LOC" || true)
echo "owner_delete $code" | tee -a "$EV/clock.txt"
code=$(curl -sS -o "$EV/del2.body" -w '%{http_code}' -X DELETE -H "authorization: Bearer $(cat "$P/alice.tok")" "http://127.0.0.1:8444$LOC" || true)
echo "repeat_delete $code" | tee -a "$EV/clock.txt"
wait $AP || true
wait $SPUB || true
echo "--- pool ---" | tee "$EV/pool.txt"
grep -E "pool after delete|expired token dropped" "$EV/edge.log" | tee -a "$EV/pool.txt" || true
echo "--- relay expiry ---" | tee "$EV/relay-expiry.txt"
grep -E "authorization token expired|session accepted" "$EV/relay.log" | tee -a "$EV/relay-expiry.txt" || true
redact < "$EV/pub.json" > "$EV/pub.redacted.json" || true
redact < "$EV/live.json" > "$EV/live.redacted.json" || true
redact < "$EV/viewer.json" > "$EV/viewer.redacted.json" || true
echo EXP_DONE
