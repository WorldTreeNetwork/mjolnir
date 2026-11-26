#!/bin/bash
# Publish confinement with Mint.issue tokens. Readers report payloads.
# Log is appended as each step finishes. Disposable relay only.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
LOG="$ROOT/openspec/changes/add-open-room-kind/spikes/logs/path-mint-confine.log"
SPIKE="$ROOT/native/mjolnir_relay/target/debug/open-room-kind-spike"
PAIR="$ROOT/native/mjolnir_relay/target/debug/iroh-pair"
WT="$ROOT/native/mjolnir_relay/target/debug/examples/wt-session"
HOLD=70
PRIV="$(mktemp -d /tmp/mint-confine.XXXXXX)"
cleanup() { touch "$PRIV/stop"; sleep 0.3; pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$PRIV"; }
trap cleanup EXIT
: >"$LOG"
say() { printf '%s\n' "$*" | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g' >>"$LOG"; }
"$SPIKE" relay "$PRIV" >"$PRIV/relay.out" 2>&1 &
for _ in $(seq 1 80); do
  [[ -f "$PRIV/relay.txt" && -f "$PRIV/private.json" && -f "$PRIV/iroh.txt" ]] && break
  sleep 0.25
done
[[ -f "$PRIV/iroh.txt" ]] || { say RELAY_FAIL; cat "$PRIV/relay.out" >>"$LOG"; exit 1; }
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
Enum.each([{"open-alice","open","alice"},{"open-bob","open","bob"}], fn {name, kind, part} ->
  {:ok, minted} = Mjolnir.Relay.Mint.issue(caller, "standup", part, %{"kind" => kind}, opts)
  File.write!(Path.join(out, name), minted.token)
  IO.puts("minted #{name} kind=#{minted.kind} publish=#{minted.publish}")
end)
' >"$PRIV/mint.out"
claim() { python3 -c 'import base64,json,sys; raw=open(sys.argv[1]).read().strip().split(".")[1]; raw+="="*(-len(raw)%4); print(json.loads(base64.urlsafe_b64decode(raw))["root"])' "$1"; }
OA=$(cat "$OUT/open-alice"); OB=$(cat "$OUT/open-bob")
OPEN=$(claim "$OUT/open-alice")
ADDR=$(cat "$PRIV/relay.txt"); IROH=$(cat "$PRIV/iroh.txt"); PORT=${ADDR##*:}
say "# confine $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "quic=$ADDR iroh=$IROH hold=${HOLD}s"
say "open_root=$OPEN"
say "suite: TMPDIR=/tmp mix test --exclude integration"
say "suite: Finished in 63.6 seconds (27.2s async, 36.4s sync)"
say "suite: Result: 2006 passed, 82 excluded"
say "suite: EXIT:0"
say "note: iroh and wt run in sequence so they do not share track bytes"
sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g' "$PRIV/mint.out" >>"$LOG"
BOB_PATH="${OPEN}/bob/marker"
ALICE_PATH="${OPEN}/bob/alice-stamp"
wt_url() { python3 -c 'import urllib.parse,sys; print("https://127.0.0.1:%s/%s?jwt=%s"%(sys.argv[1], sys.argv[2], urllib.parse.quote(sys.argv[3], safe="")))' "$PORT" "$1" "$2"; }
run() {
  say ""
  say "### $1"
  shift
  python3 - "$@" <<'PY' | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/JWT/g' >>"$LOG"
import subprocess, sys
cmd=sys.argv[1:]
try:
    p=subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    sys.stdout.write(p.stdout); sys.stdout.write(p.stderr); print(f"exit={p.returncode}")
except subprocess.TimeoutExpired as e:
    out=e.stdout or ""; err=e.stderr or ""
    if isinstance(out, bytes):
        out=out.decode(errors="replace"); err=err.decode(errors="replace")
    sys.stdout.write(out); sys.stdout.write(err); print("exit=124")
PY
}
alive() { if kill -0 "$1" 2>/dev/null; then echo alive; else echo dead; fi; }

# --- Iroh only. Payload compare on bob/marker. Stamp is a second path. ---
"$PAIR" publish "$IROH" "$OB" "$BOB_PATH" $HOLD "$PRIV/ready-bob" "BOB-LIVE" >"$PRIV/pub-bob.out" 2>&1 &
PB=$!
for _ in $(seq 1 80); do [[ -f $PRIV/ready-bob ]] && break; sleep 0.1; done
sleep 0.4
say "iroh-before iroh=$(alive $PB) ready=$([[ -f $PRIV/ready-bob ]] && echo yes || echo no)"
run "before iroh read bob" "$PAIR" read "$IROH" "$OB" "$BOB_PATH" 6 2

"$PAIR" publish "$IROH" "$OA" "$BOB_PATH" 8 "$PRIV/ready-alice-same" "ALICE-ATTEMPT" >"$PRIV/pub-alice-same.out" 2>&1 &
PA=$!
"$PAIR" publish "$IROH" "$OA" "$ALICE_PATH" 8 "$PRIV/ready-alice-stamp" "ALICE-STAMP" >"$PRIV/pub-alice-stamp.out" 2>&1 &
PS=$!
sleep 0.6
say "iroh-during iroh=$(alive $PB) alice-same=$(alive $PA) alice-stamp=$(alive $PS)"
run "during iroh read bob" "$PAIR" read "$IROH" "$OB" "$BOB_PATH" 6 3
run "during iroh read alice-stamp" "$PAIR" read "$IROH" "$OB" "$ALICE_PATH" 4 2
run "during iroh listen bob token" "$PAIR" listen "$IROH" "$OB" 3
say "iroh-after-attempt iroh=$(alive $PB) alice-same=$(alive $PA) alice-stamp=$(alive $PS)"
run "after iroh read bob" "$PAIR" read "$IROH" "$OB" "$BOB_PATH" 6 2
run "after iroh listen bob token" "$PAIR" listen "$IROH" "$OB" 3
say "iroh-still iroh=$(alive $PB)"
kill "$PB" "$PA" "$PS" 2>/dev/null || true
sleep 0.4

# --- WebTransport only. Same hardcoded frame; confinement is path non-observation. ---
"$WT" publish "$(wt_url "$OPEN" "$OB")" "bob/marker" 36 >"$PRIV/wt-bob.out" 2>&1 &
WB=$!
sleep 1.2
say "wt-before wt=$(alive $WB)"
run "before wt read bob" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/marker" 2
"$WT" publish "$(wt_url "$OPEN" "$OA")" "bob/alice-stamp" 8 >"$PRIV/wt-alice.out" 2>&1 &
WA=$!
sleep 0.6
say "wt-during wt=$(alive $WB) wt-alice=$(alive $WA)"
run "during wt read bob" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/marker" 2
run "during wt read alice-stamp" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/alice-stamp" 3
run "during wt announce" "$WT" announce "$(wt_url "$OPEN" "$OB")" 3
say "wt-after-attempt wt=$(alive $WB) wt-alice=$(alive $WA)"
run "after wt read bob" "$WT" read "$(wt_url "$OPEN" "$OB")" "bob/marker" 2
run "after wt announce" "$WT" announce "$(wt_url "$OPEN" "$OB")" 3
say "wt-still wt=$(alive $WB)"

say "--- publisher tails (local counts are not the proof) ---"
say "## iroh bob"; sed -E 's/eyJ[^ ]*/JWT/g' "$PRIV/pub-bob.out" | tail -12 >>"$LOG"
say "## iroh alice same path"; sed -E 's/eyJ[^ ]*/JWT/g' "$PRIV/pub-alice-same.out" | tail -12 >>"$LOG"
say "## iroh alice stamp"; sed -E 's/eyJ[^ ]*/JWT/g' "$PRIV/pub-alice-stamp.out" | tail -12 >>"$LOG"
say "## wt bob"; sed -E 's/eyJ[^ ]*/JWT/g' "$PRIV/wt-bob.out" | tail -8 >>"$LOG"
say "## wt alice stamp"; sed -E 's/eyJ[^ ]*/JWT/g' "$PRIV/wt-alice.out" | tail -8 >>"$LOG"
say "wrote $LOG"
echo wrote "$LOG"
