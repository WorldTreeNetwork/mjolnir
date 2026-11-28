#!/bin/bash
set -u
P=/tmp/mj15-re
BIN=/tmp/mj13-4bd-tgt/release
EV=$P/evidence
SRC=$P/src
mkdir -p "$EV"
for port in 18454 19454 18134; do
  pids=$(ss -lntup 2>/dev/null | sed -n "s/.*:${port} .*pid=\\([0-9]*\\).*/\\1/p" | sort -u)
  for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
done
redact() { sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[jwt]/g'; }
{
  echo "page_git $(git -C /home/dorje/work/IdentiKey/mjolnir rev-parse --short HEAD 2>/dev/null || echo uncommitted-sync)"
  echo "gateway_git 4bd94d1d"
  echo "chromium $(/usr/bin/chromium --version)"
  sha256sum "$BIN/mjolnir-edge" "$BIN/mjolnir-relay"
  (cd "$SRC" && find page src -type f -print0 | sort -z | xargs -0 sha256sum)
} > "$EV/identities.txt"
rm -rf "$P/state" "$P/www-root"
mkdir -p "$P/state" "$P/www-root/page" "$P/www-root/src"
cp -a "$SRC/page/." "$P/www-root/page/"
cp -a "$SRC/src/." "$P/www-root/src/"
printf 'window.MJOLNIR_ROOM_ORIGIN = "http://127.0.0.1:18454";\n' > "$P/www-root/page/config.js"
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
      IO.puts("minted #{name} ttl=#{ttl} exp=#{minted.expires}")
    other -> IO.inspect(other); System.halt(1)
  end
end
mint.("alice", 600, "alice")
mint.("alice", 600, "alice2")
mint.("bob", 600, "bob")
mint.("alice", 20, "short")
EXS
cd /home/dorje/work/IdentiKey/mjolnir
PATH="$HOME/.local/share/mise/shims:$PATH" \
  MINT_SUB="$SUB" MINT_KEY=/tmp/mj15-run/mint/current.jwk MINT_ENV=/tmp/mj15-run/relay.env MINT_OUT="$P" \
  MIX_ENV=test mix run --no-start --no-deps-check "$P/mint.exs" >"$EV/mix.txt" 2>&1 || { echo MINT_FAIL; tail -30 "$EV/mix.txt"; exit 1; }
python3 - <<PY
import pathlib
p=pathlib.Path("$P"); lines=[]
for name in ("alice","alice2","bob","short"):
    meta=(p/f"{name}.meta").read_text().splitlines(); lines.append(f"{name} root_len={len(meta[0])} exp={meta[1]}")
pathlib.Path("$EV/mint.txt").write_text("\n".join(lines)+"\n")
PY
export MJOLNIR_RELAY_HOST=localhost MJOLNIR_RELAY_BIND=127.0.0.1:19454
export MJOLNIR_RELAY_TLS_DIR=/tmp/mj15-run/tls
export MJOLNIR_RELAY_KEYS=/var/tmp/mj15-keys/relay-keys.json
export MJOLNIR_RELAY_KEYS_ACTIVE=$P/keys.active
export MJOLNIR_RELAY_STATE_DIR=$P/state
export MJOLNIR_RELAY_LOCATOR=$P/locator.json
export MJOLNIR_RELAY_TOKEN_MAX_TTL=3600
nohup "$BIN/mjolnir-relay" >"$EV/relay.log" 2>&1 &
RELAY_PID=$!
export MJOLNIR_EDGE_KEYS=/var/tmp/mj15-keys/relay-keys.json
export MJOLNIR_EDGE_RELAY=https://localhost:19454
export MJOLNIR_EDGE_TLS_ROOT=/tmp/mj15-run/tls/cert.pem
export MJOLNIR_EDGE_BIND=127.0.0.1:18454
export MJOLNIR_EDGE_MEDIA=127.0.0.1:0
export MJOLNIR_EDGE_ORIGINS=http://127.0.0.1:18134
export MJOLNIR_EDGE_MAX_TTL=3600
nohup "$BIN/mjolnir-edge" >"$EV/edge.log" 2>&1 &
EDGE_PID=$!
nohup python3 -m http.server 18134 --bind 127.0.0.1 --directory "$P/www-root" >"$EV/pages.log" 2>&1 &
PAGES_PID=$!
for i in $(seq 1 50); do grep -q "edge admission listening" "$EV/edge.log" && break; sleep 0.2; done
grep -q "edge admission listening" "$EV/edge.log" || { echo EDGE_NOT_LISTENING; tail -20 "$EV/edge.log"; kill -9 $RELAY_PID $EDGE_PID $PAGES_PID; exit 1; }
cp -f "$P/driver.mjs" /tmp/kf-pw/mj15-re-driver.mjs
cd /tmp/kf-pw
P="$P" ORIGIN=http://127.0.0.1:18454 PAGE_ORIGIN=http://127.0.0.1:18134 \
  Y4M=/tmp/mj15-run/move.y4m WAV=/tmp/mj15-run/move.wav \
  node /tmp/kf-pw/mj15-re-driver.mjs >"$EV/driver.txt" 2>&1
NODE_RC=$?
echo "node_rc=$NODE_RC" | tee -a "$EV/driver.txt"
redact < "$EV/edge.log" > "$EV/edge.sanitized.txt"
kill -9 $RELAY_PID $EDGE_PID $PAGES_PID 2>/dev/null || true
echo MJ15_RE_DONE rc=$NODE_RC
exit $NODE_RC
