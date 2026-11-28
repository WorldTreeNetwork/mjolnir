#!/bin/bash
set -u
P=/tmp/mj15-gw
BIN=/tmp/mj13-4bd-tgt/release
EV=$P/evidence
SRC=$P/src
mkdir -p "$EV"
for port in 18453 19453 18133; do
  pids=$(ss -lntup 2>/dev/null | sed -n "s/.*:${port} .*pid=\\([0-9]*\\).*/\\1/p" | sort -u)
  for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
done
redact() { sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[jwt]/g'; }

{
  echo "page_git 72ec6110"
  echo "gateway_git 4bd94d1d"
  echo "chromium $(/usr/bin/chromium --version)"
  echo "node $(node --version)"
  sha256sum "$BIN/mjolnir-edge" "$BIN/mjolnir-relay"
  echo "edge_buildid $(readelf -n "$BIN/mjolnir-edge" | awk '/Build ID/ {print $3}')"
  echo "relay_buildid $(readelf -n "$BIN/mjolnir-relay" | awk '/Build ID/ {print $3}')"
  echo "file_edge $(file -b "$BIN/mjolnir-edge")"
  echo "file_relay $(file -b "$BIN/mjolnir-relay")"
} > "$EV/identities.txt"

rm -rf "$P/state" "$P/www-root"
mkdir -p "$P/state" "$P/www-root/page" "$P/www-root/src"
cp -a "$SRC/page/." "$P/www-root/page/"
cp -a "$SRC/src/." "$P/www-root/src/"
printf 'window.MJOLNIR_ROOM_ORIGIN = "http://127.0.0.1:18453";\n' > "$P/www-root/page/config.js"
(cd "$P/www-root" && find page src -type f -print0 | sort -z | xargs -0 sha256sum) > "$EV/page-hashes.txt"

SUB=$(python3 -c 'print("09"*32)')
cat > "$P/mint.exs" <<'EXS'
owner = System.fetch_env!("MINT_SUB")
key = System.fetch_env!("MINT_KEY")
env = System.fetch_env!("MINT_ENV")
out = System.fetch_env!("MINT_OUT")
caller = %{kind: :user, scopes: "relay:join", sub: owner}
opts = [key_path: key, env_path: env, uid: 1000]
mint = fn participant, ttl, name ->
  case Mjolnir.Relay.Mint.issue(caller, "r1", participant, %{"kind" => "open", "ttl" => ttl}, opts) do
    {:ok, minted} ->
      File.write!(Path.join(out, name <> ".tok"), minted.token)
      File.write!(Path.join(out, name <> ".meta"), minted.root <> "\n" <> Integer.to_string(minted.expires) <> "\n")
      IO.puts("minted #{name} ttl=#{ttl} root_len=#{String.length(minted.root)} exp=#{minted.expires}")
    other ->
      IO.inspect(other)
      System.halt(1)
  end
end
mint.("alice", 600, "alice")
mint.("alice", 600, "alice2")
mint.("bob", 600, "bob")
mint.("alice", 2, "expired")
EXS
cd /home/dorje/work/IdentiKey/mjolnir
PATH="$HOME/.local/share/mise/shims:$PATH" \
  MINT_SUB="$SUB" MINT_KEY=/tmp/mj15-run/mint/current.jwk MINT_ENV=/tmp/mj15-run/relay.env MINT_OUT="$P" \
  MIX_ENV=test mix run --no-start --no-deps-check "$P/mint.exs" >"$EV/mix.txt" 2>&1 || { echo MINT_FAIL; tail -40 "$EV/mix.txt"; exit 1; }
python3 - <<PY
import pathlib
p = pathlib.Path("$P")
lines = []
for name in ("alice", "alice2", "bob", "expired"):
    meta = (p / f"{name}.meta").read_text().splitlines()
    lines.append(f"{name} root_len={len(meta[0])} exp={meta[1]}")
pathlib.Path("$EV/mint.txt").write_text("\n".join(lines) + "\n")
PY

export MJOLNIR_RELAY_HOST=localhost MJOLNIR_RELAY_BIND=127.0.0.1:19453
export MJOLNIR_RELAY_TLS_DIR=/tmp/mj15-run/tls
export MJOLNIR_RELAY_KEYS=/var/tmp/mj15-keys/relay-keys.json
export MJOLNIR_RELAY_KEYS_ACTIVE=$P/keys.active
export MJOLNIR_RELAY_STATE_DIR=$P/state
export MJOLNIR_RELAY_LOCATOR=$P/locator.json
export MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
nohup "$BIN/mjolnir-relay" >"$EV/relay.log" 2>&1 &
RELAY_PID=$!
export MJOLNIR_EDGE_KEYS=/var/tmp/mj15-keys/relay-keys.json
export MJOLNIR_EDGE_RELAY=https://localhost:19453
export MJOLNIR_EDGE_TLS_ROOT=/tmp/mj15-run/tls/cert.pem
export MJOLNIR_EDGE_BIND=127.0.0.1:18453
export MJOLNIR_EDGE_MEDIA=127.0.0.1:0
export MJOLNIR_EDGE_ORIGINS=http://127.0.0.1:18133
export MJOLNIR_EDGE_MAX_TTL=3600
nohup "$BIN/mjolnir-edge" >"$EV/edge.log" 2>&1 &
EDGE_PID=$!
nohup python3 -m http.server 18133 --bind 127.0.0.1 --directory "$P/www-root" >"$EV/pages.log" 2>&1 &
PAGES_PID=$!
echo "pids relay=$RELAY_PID edge=$EDGE_PID pages=$PAGES_PID" | tee "$EV/pids.txt"
for i in $(seq 1 50); do
  grep -q "edge admission listening" "$EV/edge.log" && break
  sleep 0.2
done
grep -q "edge admission listening" "$EV/edge.log" || { echo EDGE_NOT_LISTENING; tail -30 "$EV/edge.log"; kill -9 $RELAY_PID $EDGE_PID $PAGES_PID; exit 1; }

cp -f "$P/driver.mjs" /tmp/kf-pw/mj15-gw-driver.mjs
cd /tmp/kf-pw
P="$P" ORIGIN=http://127.0.0.1:18453 PAGE_ORIGIN=http://127.0.0.1:18133 \
  Y4M=/tmp/mj15-run/move.y4m WAV=/tmp/mj15-run/move.wav \
  node /tmp/kf-pw/mj15-gw-driver.mjs >"$EV/driver.txt" 2>&1
NODE_RC=$?
echo "node_rc=$NODE_RC" | tee -a "$EV/driver.txt"
redact < "$EV/edge.log" > "$EV/edge.sanitized.log"
redact < "$EV/relay.log" > "$EV/relay.sanitized.log"
grep -E "whip publish|whep|DELETE|admit|listening|connected|drain|not_started|forbidden" "$EV/edge.sanitized.log" > "$EV/edge.events.txt" || true
kill -9 $RELAY_PID $EDGE_PID $PAGES_PID 2>/dev/null || true
echo MJ15_GW_DONE rc=$NODE_RC
exit $NODE_RC
