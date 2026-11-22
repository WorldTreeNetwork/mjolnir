#!/bin/bash
# Temp-root harness for scripts/relay-mint-key.sh.
# Covers confirmation failure, each crash point, and emergency then a re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/scripts/relay-mint-key.sh}"
WORK="$(mktemp -d)"
CONFIRM_PID=""
cleanup() {
  if [[ -n "$CONFIRM_PID" ]]; then
    kill "$CONFIRM_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/etc" "$WORK/run"
export PATH="$WORK/bin:${PATH}"
export RELAY_MINT_DIR="$WORK/mint"
export RELAY_KEYS="$WORK/etc/relay-keys.json"
export RELAY_ACTIVE="$WORK/run/keys.active"
export RELAY_ENV="$WORK/etc/relay.env"
export RELAY_BIN="$WORK/bin/mjolnir-relay"
export RELAY_CONFIRM_TRIES=3
export RELAY_CONFIRM_SLEEP=0.1
export RELAY_RESTART_CMD="${RELAY_RESTART_CMD:-true}"
printf 'MJOLNIR_RELAY_TOKEN_MAX_TTL=3600\nMJOLNIR_RELAY_DRAIN_SECONDS=15\n' > "$RELAY_ENV"

cat > "$WORK/bin/flock" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$WORK/bin/flock"

cat > "$WORK/bin/mjolnir-relay" << 'EOF'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if args[:1] == ["--check-keys"]:
    doc = json.load(open(args[1]))
    keys = doc.get("keys") or []
    if not keys:
        raise SystemExit("empty")
    seen = set()
    for key in keys:
        if "d" in key or "k" in key:
            raise SystemExit("private")
        kid = key.get("kid")
        if not kid or kid in seen:
            raise SystemExit("kid")
        seen.add(kid)
    raise SystemExit(0)
if args[:1] == ["--public-from-private"]:
    priv = json.load(open(args[1]))
    pub = {k: priv[k] for k in ("kty", "crv", "alg", "kid", "x")}
    print(json.dumps({"keys": [pub]}))
    raise SystemExit(0)
if args[:1] == ["--write-mint-key"]:
    dest, kid = args[1], args[2]
    priv = {"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid, "x": "x-" + kid, "d": "d-" + kid}
    open(dest, "w").write(json.dumps(priv))
    pub = {k: priv[k] for k in ("kty", "crv", "alg", "kid", "x")}
    print(json.dumps({"keys": [pub]}))
    raise SystemExit(0)
raise SystemExit("usage")
EOF
chmod 755 "$WORK/bin/mjolnir-relay"

mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
kids_of() { python3 -c 'import json,sys; print(" ".join(k["kid"] for k in json.load(open(sys.argv[1]))["keys"]))' "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

reset_mint() {
  rm -rf "$RELAY_MINT_DIR"
  mkdir -p "$RELAY_MINT_DIR"
  chmod 0700 "$RELAY_MINT_DIR"
}

seed_current() {
  local kid="$1"
  python3 - "$RELAY_MINT_DIR" "$kid" << 'PY'
import json, os, sys
mint, kid = sys.argv[1], sys.argv[2]
priv = {"kty":"OKP","crv":"Ed25519","alg":"EdDSA","kid":kid,"x":"x-"+kid,"d":"d-"+kid}
path = os.path.join(mint, "current.jwk")
open(path,"w").write(json.dumps(priv))
os.chmod(path, 0o600)
pub = {k: priv[k] for k in ("kty","crv","alg","kid","x")}
open(path+".pub","w").write(json.dumps({"keys":[pub]}))
PY
}

write_public() {
  python3 - "$RELAY_KEYS" "$@" << 'PY'
import json, sys
path, kids = sys.argv[1], sys.argv[2:]
keys = [{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","kid":kid,"x":"x-"+kid} for kid in kids]
open(path,"w").write(json.dumps({"keys": keys}))
PY
  chmod 0644 "$RELAY_KEYS"
}

start_confirm() {
  if [[ -n "$CONFIRM_PID" ]]; then
    return
  fi
  (
    while true; do
      if [[ -f "$RELAY_KEYS" ]]; then
        openssl dgst -sha256 "$RELAY_KEYS" | awk '{print $NF}' > "$RELAY_ACTIVE"
      fi
      sleep 0.05
    done
  ) &
  CONFIRM_PID=$!
}

stop_confirm() {
  if [[ -n "$CONFIRM_PID" ]]; then
    kill "$CONFIRM_PID" 2>/dev/null || true
    wait "$CONFIRM_PID" 2>/dev/null || true
    CONFIRM_PID=""
  fi
  rm -f "$RELAY_ACTIVE"
}

# Confirmation failure on rotate restores the previous set at 0644.
reset_mint
seed_current kept
write_public kept
stop_confirm
set +e
RELAY_MINT_KID=rotated "$SCRIPT" >"$WORK/rotate.out" 2>"$WORK/rotate.err"
rc=$?
set -e
[[ "$rc" != 0 ]] || fail "rotate confirmation succeeded"
[[ "$(mode_of "$RELAY_KEYS")" == "0o644" ]] || fail "rotate mode $(mode_of "$RELAY_KEYS")"
[[ "$(kids_of "$RELAY_KEYS")" == "kept" ]] || fail "rotate kids $(kids_of "$RELAY_KEYS")"
echo "rotate confirmation failure: ok"

# A confirmed overlap, then finish confirmation failure restores both kids.
start_confirm
RELAY_MINT_KID=rotated "$SCRIPT" >"$WORK/rotate-ok.out"
[[ "$(kids_of "$RELAY_KEYS")" == *"kept"* && "$(kids_of "$RELAY_KEYS")" == *"rotated"* ]] || fail "overlap $(kids_of "$RELAY_KEYS")"
python3 -c 'import json,os; p=os.environ["RELAY_MINT_DIR"]+"/rotation.json"; d=json.load(open(p)); d["not_before"]=1; json.dump(d, open(p,"w"))'
# The hash in state must still match the file. not_before edit does not change the set.
stop_confirm
set +e
"$SCRIPT" finish >"$WORK/finish.out" 2>"$WORK/finish.err"
rc=$?
set -e
[[ "$rc" != 0 ]] || fail "finish confirmation succeeded"
[[ "$(mode_of "$RELAY_KEYS")" == "0o644" ]] || fail "finish mode $(mode_of "$RELAY_KEYS")"
[[ "$(kids_of "$RELAY_KEYS")" == *"kept"* && "$(kids_of "$RELAY_KEYS")" == *"rotated"* ]] || fail "finish kids $(kids_of "$RELAY_KEYS")"
echo "finish confirmation failure: ok"

# Crash points. Each must exit 75 and a later run must keep the new signer in the set.
start_confirm
for step in generate published confirmed state signer_priv; do
  reset_mint
  seed_current kept
  write_public kept
  set +e
  RELAY_MINT_KID=nextkid RELAY_MINT_KEY_FAIL_AFTER="$step" "$SCRIPT" >"$WORK/stop.out" 2>"$WORK/stop.err"
  rc=$?
  set -e
  [[ "$rc" == 75 ]] || fail "$step rc=$rc $(cat "$WORK/stop.err")"
  unset RELAY_MINT_KEY_FAIL_AFTER
  "$SCRIPT" >"$WORK/recover.out"
  [[ "$(kids_of "$RELAY_KEYS")" == *"nextkid"* ]] || fail "$step recovery kids $(kids_of "$RELAY_KEYS")"
  echo "crash $step: ok"
done

# Emergency publishes, dies, and a bare re-run must not return the old kid.
reset_mint
seed_current stolen
write_public stolen
set +e
RELAY_MINT_KID=fresh RELAY_MINT_KEY_FAIL_AFTER=emergency_published "$SCRIPT" emergency >"$WORK/em.out" 2>"$WORK/em.err"
rc=$?
set -e
[[ "$rc" == 75 ]] || fail "emergency_published rc=$rc $(cat "$WORK/em.err")"
[[ ! -f "$RELAY_MINT_DIR/current.jwk" ]] || fail "current.jwk survived emergency publish"
unset RELAY_MINT_KEY_FAIL_AFTER
"$SCRIPT" >"$WORK/rerun.out"
[[ "$(kids_of "$RELAY_KEYS")" == "fresh" ]] || fail "re-run kids $(kids_of "$RELAY_KEYS")"
[[ "$(kids_of "$RELAY_KEYS")" != *"stolen"* ]] || fail "stolen kid returned"
echo "emergency re-run: ok"

# Restart failure is non-zero even when confirmation succeeds.
reset_mint
seed_current stolen
write_public stolen
set +e
RELAY_MINT_KID=fresh2 RELAY_RESTART_CMD=false "$SCRIPT" emergency >"$WORK/em2.out" 2>"$WORK/em2.err"
rc=$?
set -e
[[ "$rc" != 0 ]] || fail "restart failure exited 0"
echo "emergency restart failure: ok"

# Empty keys.active does not confirm.
reset_mint
seed_current kept
write_public kept
stop_confirm
: > "$RELAY_ACTIVE"
set +e
RELAY_MINT_KID=nope "$SCRIPT" >"$WORK/empty.out" 2>"$WORK/empty.err"
rc=$?
set -e
[[ "$rc" != 0 ]] || fail "empty hash confirmed"
echo "empty hash: ok"

echo "relay-mint-key harness: ok"
