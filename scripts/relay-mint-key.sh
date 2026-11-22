#!/bin/bash
# Root rotation of the room-token mint key.
#
#   relay-mint-key.sh            start a routine rotation, or a first install
#   relay-mint-key.sh finish     drop the old public key after the overlap
#   relay-mint-key.sh emergency  replace the public set at once and restart
#
# After a failed or interrupted emergency, current.jwk is already gone.
# Run the same default command again. It takes the first-install path and
# reuses staged.jwk. It does not publish the key emergency removed.
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
install -d -m 0755 "$(dirname "$KEYS")"
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
  line="${line%\"}"
  line="${line#\"}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
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
  line="${line%\"}"
  line="${line#\"}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
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

# A missing sidecar is derived by the relay binary from the private file.
# An existing sidecar is kept when kid and x already match.
heal_sidecar() {
  local priv="$1"
  if python3 - "$priv" <<'PY'
import json, os, sys
path = sys.argv[1]
priv = json.load(open(path))
side = path + ".pub"
if not os.path.exists(side):
    sys.exit(1)
doc = json.load(open(side))
members = doc["keys"] if isinstance(doc, dict) and "keys" in doc else [doc]
ok = (
    len(members) == 1
    and members[0].get("kid") == priv.get("kid")
    and members[0].get("x") == priv.get("x")
    and "d" not in members[0]
    and "k" not in members[0]
)
sys.exit(0 if ok else 1)
PY
  then
    chmod 0644 "${priv}.pub"
    return 0
  fi
  "$BIN" --public-from-private "$priv" > "${priv}.pub"
  chmod 0644 "${priv}.pub"
}

# Candidate and previous live beside the target so the rename stays on one
# filesystem. Mode 0644 is set before the rename.
beside() {
  mktemp "${KEYS}.XXXXXX"
}

# Write a public key set from each private file. A sidecar, when present,
# must carry the same kid and x. The published JWK is the private file
# with d and k removed.
write_public_set() {
  local out="$1"
  shift
  python3 - "$out" "$@" <<'PY'
import json, os, re, sys
out, paths = sys.argv[1], sys.argv[2:]
kid_re = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
allowed = {"EdDSA", "ES256"}
seen = set()
keys = []
for path in paths:
    priv = json.load(open(path))
    if "d" not in priv and "k" not in priv:
        sys.exit("relay-mint-key: refusing to publish a public-only file")
    kid = priv.get("kid")
    x = priv.get("x")
    alg = priv.get("alg")
    if alg not in allowed:
        sys.exit(f"relay-mint-key: disallowed algorithm {alg!r}")
    if not isinstance(kid, str) or not kid_re.match(kid) or not isinstance(x, str) or not x:
        sys.exit("relay-mint-key: kid refused before publish")
    side = path + ".pub"
    if os.path.exists(side):
        doc = json.load(open(side))
        members = doc["keys"] if isinstance(doc, dict) and "keys" in doc else [doc]
        if len(members) != 1 or members[0].get("kid") != kid or members[0].get("x") != x:
            sys.exit("relay-mint-key: sidecar kid or x does not match the private file")
    if kid in seen:
        sys.exit(f"relay-mint-key: duplicate kid {kid}")
    seen.add(kid)
    if not os.path.exists(side):
        sys.exit("relay-mint-key: public sidecar missing")
    keys.append(members[0])
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
  want="$(sha256_file "$path" 2>/dev/null || true)"
  if [[ -z "$want" ]]; then
    echo "relay-mint-key: no hash for $(basename "$path")" >&2
    return 1
  fi
  local tries="${RELAY_CONFIRM_TRIES:-10}"
  for ((i = 1; i <= tries; i++)); do
    if [[ -f "$ACTIVE" ]]; then
      got="$(tr -d '[:space:]' < "$ACTIVE")"
    else
      got=""
    fi
    if [[ -n "$got" && "$got" == "$want" ]]; then
      return 0
    fi
    sleep "${RELAY_CONFIRM_SLEEP:-1}"
  done
  echo "relay-mint-key: keys.active did not match $(basename "$path") within ${tries} tries" >&2
  return 1
}

write_state() {
  local kid="$1" not_before="$2" hash="$3"
  python3 -c 'import json,sys; json.dump({"kid":sys.argv[1],"not_before":int(sys.argv[2]),"set_hash":sys.argv[3]}, open(sys.argv[4],"w"))' \
    "$kid" "$not_before" "$hash" "$STATE"
  chmod 0600 "$STATE"
}

overlap_deadline() {
  echo "$(( $(date +%s) + $(ceiling_seconds) + 60 ))"
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
  tmp="$(beside)"
  chmod 0644 "$tmp"
  if ! write_public_set "$tmp" "$@"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp"
  if ! check_set "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$candidate"
  chmod 0644 "$candidate"
}

install_public() {
  local src="$1"
  chmod 0644 "$src"
  mv -f "$src" "$KEYS"
  chmod 0644 "$KEYS"
}

save_previous() {
  local prev
  prev="$(beside)"
  chmod 0644 "$prev"
  if [[ -f "$KEYS" ]]; then
    cp -f "$KEYS" "$prev"
  fi
  chmod 0644 "$prev"
  printf '%s' "$prev"
}

restore_previous() {
  local prev="$1"
  chmod 0644 "$prev"
  mv -f "$prev" "$KEYS"
  chmod 0644 "$KEYS"
}

# Move a private key onto its destination, then its sidecar.
# A crash between the two renames is healed from the private file.
install_signer() {
  local src="$1" dest="$2"
  heal_sidecar "$src"
  mv -f "$src" "$dest"
  chmod 0600 "$dest"
  stop_after signer_priv
  if [[ -f "${src}.pub" ]]; then
    mv -f "${src}.pub" "${dest}.pub"
  fi
  heal_sidecar "$dest"
  chmod 0600 "$dest"
  chmod 0644 "${dest}.pub"
}

restart_relay() {
  if [[ -n "${RELAY_RESTART_CMD:-}" ]]; then
    # shellcheck disable=SC2086
    eval "$RELAY_RESTART_CMD"
  else
    systemctl restart "$UNIT"
  fi
}

resume_overlap() {
  local want hash have next_kid active_hash not_before
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$STATE")"
  hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("set_hash") or "")' "$STATE")"
  if [[ -z "$hash" || "$(sha256_file "$KEYS")" != "$hash" ]]; then
    echo "relay-mint-key: public set does not match rotation.json set_hash; oldest key kept" >&2
    exit 1
  fi
  if [[ ! -f "$ACTIVE" ]]; then
    echo "relay-mint-key: keys.active is missing; overlap not resumed" >&2
    exit 1
  fi
  active_hash="$(tr -d '[:space:]' < "$ACTIVE")"
  if [[ -z "$active_hash" || "$active_hash" != "$hash" ]]; then
    echo "relay-mint-key: keys.active does not match rotation.json set_hash" >&2
    exit 1
  fi
  have=""
  if [[ -f "$CURRENT" ]]; then
    have="$(jwk_kid "$CURRENT")"
  fi
  next_kid=""
  if [[ -f "$NEXT" ]]; then
    next_kid="$(jwk_kid "$NEXT")"
  fi
  if [[ "$have" != "$want" ]]; then
    if [[ "$next_kid" == "$want" ]]; then
      install_signer "$NEXT" "$CURRENT"
    else
      echo "relay-mint-key: signer kid does not match rotation.json" >&2
      exit 1
    fi
  else
    heal_sidecar "$CURRENT"
  fi
  not_before="$(overlap_deadline)"
  write_state "$want" "$not_before" "$hash"
  echo "relay-mint-key: overlap resumed for $want; run finish after $not_before"
  exit 0
}

first_install() {
  local kid
  if [[ ! -f "$STAGED" ]]; then
    kid="$(new_kid)"
    generate_into "$STAGED" "$kid"
  fi
  heal_sidecar "$STAGED"
  local candidate
  candidate="$(beside)"
  if ! publish_checked "$candidate" "$STAGED"; then
    rm -f "$candidate" "$STAGED" "${STAGED}.pub"
    exit 1
  fi
  install_public "$candidate"
  if ! confirm_active "$KEYS"; then
    echo "relay-mint-key: relay did not confirm the new public set; current.jwk was not written" >&2
    exit 1
  fi
  install_signer "$STAGED" "$CURRENT"
  echo "relay-mint-key: first install confirmed $(jwk_kid "$CURRENT")"
}

rotate() {
  if [[ -f "$STATE" ]]; then
    resume_overlap
  fi
  if [[ ! -f "$CURRENT" ]]; then
    first_install
    return
  fi
  heal_sidecar "$CURRENT"
  if [[ ! -f "$NEXT" ]]; then
    generate_into "$NEXT" "$(new_kid)"
    stop_after generate
  fi
  heal_sidecar "$NEXT"
  local candidate
  candidate="$(beside)"
  if ! publish_checked "$candidate" "$CURRENT" "$NEXT"; then
    rm -f "$candidate" "$NEXT" "${NEXT}.pub"
    echo "relay-mint-key: candidate rolled back; signer unchanged" >&2
    exit 1
  fi
  local previous
  previous="$(save_previous)"
  install_public "$candidate"
  stop_after published
  if ! confirm_active "$KEYS"; then
    restore_previous "$previous"
    echo "relay-mint-key: restored the previous public set; signer unchanged" >&2
    exit 1
  fi
  rm -f "$previous"
  stop_after confirmed
  local not_before hash kid
  not_before="$(overlap_deadline)"
  hash="$(sha256_file "$KEYS")"
  kid="$(jwk_kid "$NEXT")"
  write_state "$kid" "$not_before" "$hash"
  stop_after state
  install_signer "$NEXT" "$CURRENT"
  echo "relay-mint-key: signer is $kid; run finish after $not_before"
}

finish() {
  if [[ ! -f "$STATE" ]]; then
    echo "relay-mint-key: no rotation.json; nothing to finish" >&2
    exit 1
  fi
  local not_before now kid hash active_hash
  not_before="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["not_before"]))' "$STATE")"
  kid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$STATE")"
  hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("set_hash") or "")' "$STATE")"
  now="$(date +%s)"
  if (( now < not_before )); then
    echo "relay-mint-key: refusing to drop the old public key before $not_before" >&2
    exit 1
  fi
  if [[ ! -f "$CURRENT" || "$(jwk_kid "$CURRENT")" != "$kid" ]]; then
    echo "relay-mint-key: current.jwk is not $kid; old public key kept" >&2
    exit 1
  fi
  if [[ -z "$hash" || "$(sha256_file "$KEYS")" != "$hash" ]]; then
    echo "relay-mint-key: public set does not match rotation.json; old public key kept" >&2
    exit 1
  fi
  heal_sidecar "$CURRENT"
  local candidate previous
  candidate="$(beside)"
  if ! publish_checked "$candidate" "$CURRENT"; then
    rm -f "$candidate"
    exit 1
  fi
  previous="$(save_previous)"
  install_public "$candidate"
  if ! confirm_active "$KEYS"; then
    restore_previous "$previous"
    echo "relay-mint-key: restored the two-key set; old public key kept" >&2
    exit 1
  fi
  rm -f "$previous" "$STATE" "$NEXT" "${NEXT}.pub"
  echo "relay-mint-key: public set is $kid only"
}

emergency() {
  say_drain
  rm -f "$NEXT" "${NEXT}.pub" "$STATE"
  local kid
  if [[ ! -f "$STAGED" ]]; then
    kid="$(new_kid)"
    generate_into "$STAGED" "$kid"
  else
    kid="$(jwk_kid "$STAGED")"
  fi
  heal_sidecar "$STAGED"
  local candidate
  candidate="$(beside)"
  if ! publish_checked "$candidate" "$STAGED"; then
    rm -f "$candidate" "$STAGED" "${STAGED}.pub"
    exit 1
  fi
  # The new set stays even when confirmation fails. The compromised signer
  # is removed at the same moment, so a re-run cannot publish it again.
  install_public "$candidate"
  rm -f "$CURRENT" "${CURRENT}.pub"
  stop_after emergency_published
  local confirmed=0 restarted=0
  if confirm_active "$KEYS"; then
    confirmed=1
    install_signer "$STAGED" "$CURRENT"
  else
    echo "relay-mint-key: confirmation failed; new public set left in place; current.jwk removed; re-run: relay-mint-key.sh" >&2
  fi
  if restart_relay; then
    restarted=1
  else
    echo "relay-mint-key: relay restart failed" >&2
  fi
  say_drain
  if (( confirmed == 0 || restarted == 0 )); then
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
