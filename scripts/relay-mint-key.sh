#!/bin/bash
# Root rotation of the room-token mint key.
#
#   relay-mint-key.sh            start a routine rotation, or a first install
#   relay-mint-key.sh finish     drop the old public key after the overlap
#   relay-mint-key.sh emergency  replace the public set at once and restart
#
# flock covers all three. Step 5 is `finish`, not a sleep in this process.
# A live session signed by a removed key stays up for the drain the relay
# loaded at start (MJOLNIR_RELAY_DRAIN_SECONDS, default 30). This script
# does not shorten that drain.
set -euo pipefail

MINT_DIR="${RELAY_MINT_DIR:-/var/lib/mjolnir/relay-mint}"
KEYS="${RELAY_KEYS:-/etc/mjolnir-relay/relay-keys.json}"
ACTIVE="${RELAY_ACTIVE:-/run/mjolnir-relay/keys.active}"
ENV_FILE="${RELAY_ENV:-/etc/mjolnir-relay/relay.env}"
BIN="${RELAY_BIN:-mjolnir-relay}"
UNIT="${RELAY_UNIT:-mjolnir-relay}"
LOCK="$MINT_DIR/rotation.lock"
STATE="$MINT_DIR/rotation.json"
CURRENT="$MINT_DIR/current.jwk"
NEXT="$MINT_DIR/next.jwk"
STAGED="$MINT_DIR/staged.jwk"

install -d -m 0700 "$MINT_DIR"
touch "$LOCK"
chmod 0600 "$LOCK"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "relay-mint-key: another rotation holds $LOCK" >&2
  exit 1
fi

cmd="${1:-rotate}"

# Test hook. A real crash is this exit. The next run must recover.
stop_after() {
  if [[ "${RELAY_MINT_KEY_FAIL_AFTER:-}" == "$1" ]]; then
    echo "relay-mint-key: stopped after $1" >&2
    exit 75
  fi
}

drain_seconds() {
  local line
  line="$(grep -E '^MJOLNIR_RELAY_DRAIN_SECONDS=' "$ENV_FILE" 2>/dev/null | tail -1 || true)"
  line="${line#MJOLNIR_RELAY_DRAIN_SECONDS=}"
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    echo "$line"
  else
    echo 30
  fi
}

ceiling_seconds() {
  local line
  line="$(grep -E '^MJOLNIR_RELAY_TOKEN_MAX_TTL=' "$ENV_FILE" 2>/dev/null | tail -1 || true)"
  line="${line#MJOLNIR_RELAY_TOKEN_MAX_TTL=}"
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    echo "$line"
  else
    echo 3600
  fi
}

say_drain() {
  local drain
  drain="$(drain_seconds)"
  echo "relay-mint-key: a live session signed by the removed key stays up for ${drain}s after SIGTERM (MJOLNIR_RELAY_DRAIN_SECONDS). This script does not shorten that drain."
}

sha256_file() {
  openssl dgst -sha256 "$1" | awk '{print $NF}'
}

kid_ok() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

new_kid() {
  if [[ -n "${RELAY_MINT_KID:-}" ]]; then
    printf '%s' "$RELAY_MINT_KID"
    return
  fi
  openssl rand -base64 16 | tr '+/' '-_' | tr -d '='
}

# Print the kid of a private JWK. Empty when the field is missing.
jwk_kid() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("kid") or "")' "$1"
}

# Write a public key set from the `.pub` files `--write-mint-key` printed.
# Each of those is already a one-key public set. Refuse a bad algorithm, a
# missing or illegal kid, or two keys that share a kid.
write_public_set() {
  local out="$1"
  shift
  python3 - "$out" "$@" <<'PY'
import json, re, sys
out, paths = sys.argv[1], sys.argv[2:]
kid_re = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
allowed = {"EdDSA", "ES256"}
seen = set()
keys = []
for path in paths:
    doc = json.load(open(path + ".pub"))
    members = doc["keys"] if isinstance(doc, dict) and "keys" in doc else [doc]
    for raw in members:
        if "d" in raw or "k" in raw:
            sys.exit(f"relay-mint-key: public sidecar still holds private material")
        alg = raw.get("alg")
        kid = raw.get("kid")
        if alg not in allowed:
            sys.exit(f"relay-mint-key: disallowed algorithm {alg!r}")
        if not isinstance(kid, str) or not kid_re.match(kid):
            sys.exit("relay-mint-key: kid refused before publish")
        if kid in seen:
            sys.exit(f"relay-mint-key: duplicate kid {kid}")
        seen.add(kid)
        keys.append(raw)
if not keys:
    sys.exit("relay-mint-key: empty public set")
json.dump({"keys": keys}, open(out, "w"))
PY
}

check_set() {
  local path="$1"
  if ! "$BIN" --check-keys "$path"; then
    echo "relay-mint-key: --check-keys refused $path" >&2
    return 1
  fi
}

confirm_active() {
  local path="$1"
  local want got i
  want="$(sha256_file "$path")"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -f "$ACTIVE" ]]; then
      got="$(tr -d '[:space:]' < "$ACTIVE")"
    else
      got=""
    fi
    if [[ "$got" == "$want" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "relay-mint-key: keys.active did not match $(basename "$path") within 10s" >&2
  return 1
}

write_state() {
  local kid="$1" not_before="$2" hash="$3"
  python3 -c 'import json,sys; json.dump({"kid":sys.argv[1],"not_before":int(sys.argv[2]),"set_hash":sys.argv[3]}, open(sys.argv[4],"w"))' \
    "$kid" "$not_before" "$hash" "$STATE"
  chmod 0600 "$STATE"
}

generate_into() {
  local dest="$1" kid="$2"
  if ! kid_ok "$kid"; then
    echo "relay-mint-key: kid refused before publish: $kid" >&2
    return 1
  fi
  "$BIN" --write-mint-key "$dest" "$kid" > "${dest}.pub"
  chmod 0600 "$dest"
  chmod 0644 "${dest}.pub"
}

publish_checked() {
  local candidate="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  if ! write_public_set "$tmp" "$@"; then
    rm -f "$tmp"
    return 1
  fi
  if ! check_set "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$candidate"
}

restart_relay() {
  if [[ -n "${RELAY_RESTART_CMD:-}" ]]; then
    # shellcheck disable=SC2086
    eval "$RELAY_RESTART_CMD"
  else
    systemctl restart "$UNIT"
  fi
}

first_install() {
  local kid
  if [[ ! -f "$STAGED" ]]; then
    kid="$(new_kid)"
    generate_into "$STAGED" "$kid"
  fi
  local candidate
  candidate="$(mktemp)"
  if ! publish_checked "$candidate" "$STAGED"; then
    rm -f "$candidate" "$STAGED"
    exit 1
  fi
  # Replace any fixture already in the public file. On a missed confirmation
  # the new set stays and current.jwk is not written.
  mv -f "$candidate" "$KEYS"
  chmod 0644 "$KEYS"
  if ! confirm_active "$KEYS"; then
    echo "relay-mint-key: relay did not confirm the new public set; current.jwk was not written" >&2
    exit 1
  fi
  mv -f "$STAGED" "$CURRENT"
  mv -f "${STAGED}.pub" "${CURRENT}.pub"
  chmod 0600 "$CURRENT"
  chmod 0644 "${CURRENT}.pub"
  echo "relay-mint-key: first install confirmed $(jwk_kid "$CURRENT")"
}

rotate() {
  if [[ -f "$STATE" ]]; then
    local want have
    want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$STATE")"
    have="$(jwk_kid "$CURRENT")"
    if [[ "$have" != "$want" && -f "$NEXT" ]]; then
      mv -f "$NEXT" "$CURRENT"
      mv -f "${NEXT}.pub" "${CURRENT}.pub"
      chmod 0600 "$CURRENT"
      chmod 0644 "${CURRENT}.pub"
      echo "relay-mint-key: finished the signer rename for $want; run finish after the overlap"
      exit 0
    fi
    echo "relay-mint-key: an overlap is unfinished; the oldest public key stays" >&2
    exit 1
  fi
  if [[ ! -f "$CURRENT" ]]; then
    first_install
    return
  fi
  if [[ ! -f "$NEXT" ]]; then
    generate_into "$NEXT" "$(new_kid)"
    stop_after generate
  fi
  local candidate
  candidate="$(mktemp)"
  if ! publish_checked "$candidate" "$CURRENT" "$NEXT"; then
    rm -f "$candidate" "$NEXT"
    echo "relay-mint-key: candidate rolled back; signer unchanged" >&2
    exit 1
  fi
  local previous
  previous="$(mktemp)"
  cp -f "$KEYS" "$previous"
  mv -f "$candidate" "$KEYS"
  chmod 0644 "$KEYS"
  stop_after published
  if ! confirm_active "$KEYS"; then
    mv -f "$previous" "$KEYS"
    echo "relay-mint-key: restored the previous public set; signer unchanged" >&2
    exit 1
  fi
  rm -f "$previous"
  stop_after confirmed
  local not_before hash kid
  not_before="$(( $(date +%s) + $(ceiling_seconds) + 60 ))"
  hash="$(sha256_file "$KEYS")"
  kid="$(jwk_kid "$NEXT")"
  write_state "$kid" "$not_before" "$hash"
  stop_after state
  mv -f "$NEXT" "$CURRENT"
  mv -f "${NEXT}.pub" "${CURRENT}.pub"
  chmod 0600 "$CURRENT"
  chmod 0644 "${CURRENT}.pub"
  echo "relay-mint-key: signer is $kid; run finish after $not_before"
}

finish() {
  if [[ ! -f "$STATE" ]]; then
    echo "relay-mint-key: no rotation.json; nothing to finish" >&2
    exit 1
  fi
  local not_before now kid
  not_before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["not_before"])' "$STATE")"
  kid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$STATE")"
  now="$(date +%s)"
  if (( now < not_before )); then
    echo "relay-mint-key: refusing to drop the old public key before $not_before" >&2
    exit 1
  fi
  if [[ "$(jwk_kid "$CURRENT")" != "$kid" ]]; then
    echo "relay-mint-key: current.jwk is not $kid; old public key kept" >&2
    exit 1
  fi
  local candidate previous
  candidate="$(mktemp)"
  if ! publish_checked "$candidate" "$CURRENT"; then
    rm -f "$candidate"
    exit 1
  fi
  previous="$(mktemp)"
  cp -f "$KEYS" "$previous"
  mv -f "$candidate" "$KEYS"
  chmod 0644 "$KEYS"
  if ! confirm_active "$KEYS"; then
    mv -f "$previous" "$KEYS"
    echo "relay-mint-key: restored the two-key set; old public key kept" >&2
    exit 1
  fi
  rm -f "$previous" "$STATE" "$NEXT"
  echo "relay-mint-key: public set is $kid only"
}

emergency() {
  say_drain
  rm -f "$NEXT" "$STATE"
  local kid
  kid="$(new_kid)"
  generate_into "$STAGED" "$kid"
  local candidate
  candidate="$(mktemp)"
  if ! publish_checked "$candidate" "$STAGED"; then
    rm -f "$candidate" "$STAGED"
    exit 1
  fi
  # Never restore the previous public set. A failed confirmation leaves the
  # new set for the relay to load when it is up.
  mv -f "$candidate" "$KEYS"
  chmod 0644 "$KEYS"
  local confirmed=0
  if confirm_active "$KEYS"; then
    confirmed=1
    mv -f "$STAGED" "$CURRENT"
    mv -f "${STAGED}.pub" "${CURRENT}.pub"
    chmod 0600 "$CURRENT"
    chmod 0644 "${CURRENT}.pub"
  else
    echo "relay-mint-key: confirmation failed; new public set left in place; current.jwk unchanged" >&2
  fi
  restart_relay || true
  say_drain
  if (( confirmed == 0 )); then
    exit 1
  fi
  echo "relay-mint-key: emergency signer is $kid"
}

case "$cmd" in
  rotate) rotate ;;
  finish) finish ;;
  emergency) emergency ;;
  *)
    echo "usage: relay-mint-key.sh [rotate|finish|emergency]" >&2
    exit 2
    ;;
esac
