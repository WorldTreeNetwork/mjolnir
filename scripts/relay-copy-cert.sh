#!/usr/bin/env bash
# Root copies one relay certificate pair into a new generation, then renames current.
# The running unit is not restarted. See docs/decisions/0016-edge-relay.md.
set -euo pipefail
SRC_CERT="${1:?source cert.pem}"
SRC_KEY="${2:?source key.pem}"
HOST_NAME="${3:?relay host name}"
DEST_ROOT="${4:-/var/lib/mjolnir-relay/tls}"
RELAY_GROUP="${5:-mjolnir-relay}"

refuse() { echo "relay-copy-cert: $*" >&2; exit 1; }

[[ -f "$SRC_CERT" && -f "$SRC_KEY" ]] || refuse "source pair missing"

# Every component from / to the tls directory is root-owned, not a symlink,
# and not writable by anyone but root. Write nothing if that is not true.
check_component() {
    local path="$1"
    [[ -L "$path" ]] && refuse "symlink: $path"
    local owner mode
    owner="$(stat -c '%u' "$path")"
    mode="$(stat -c '%a' "$path")"
    [[ "$owner" == 0 ]] || refuse "not root-owned: $path"
    local other="${mode: -1}"
    local group="${mode: -2:1}"
    # Any write bit besides the owner's is a foreign writer.
    [[ "$group" == 0 || "$group" == 1 || "$group" == 4 || "$group" == 5 ]] || refuse "group-writable: $path"
    [[ "$other" == 0 || "$other" == 1 || "$other" == 4 || "$other" == 5 ]] || refuse "other-writable: $path"
}

path="$DEST_ROOT"
while [[ "$path" != "/" ]]; do
    if [[ -e "$path" || -L "$path" ]]; then
        check_component "$path"
    fi
    path="$(dirname "$path")"
done

openssl x509 -in "$SRC_CERT" -noout -checkend 0 >/dev/null 2>&1 || refuse "certificate is expired"
# Whole name. A suffix such as relay.example.net.evil.org does not match.
openssl x509 -in "$SRC_CERT" -noout -checkhost "$HOST_NAME" >/dev/null 2>&1 || refuse "certificate does not name ${HOST_NAME}"
[[ "$(id -u)" == 0 ]] || refuse "must run as root"

cert_pub="$(openssl x509 -in "$SRC_CERT" -noout -pubkey)"
key_pub="$(openssl pkey -in "$SRC_KEY" -pubout 2>/dev/null || true)"
[[ -n "$key_pub" && "$cert_pub" == "$key_pub" ]] || refuse "key does not match the leaf"

# Same owner and mode as relay-deploy-remote.sh. The relay user cannot write this tree.
install -d -o root -g "$RELAY_GROUP" -m 0750 "$(dirname "$DEST_ROOT")"
if [[ -d "$DEST_ROOT" ]]; then
    check_component "$DEST_ROOT"
else
    install -d -o root -g "$RELAY_GROUP" -m 0750 "$DEST_ROOT"
fi

gen="$DEST_ROOT/gen-$(date -u +%Y%m%dT%H%M%SZ)-$$"
# Private before any key byte. Other users cannot read the staged key.
install -d -o root -g "$RELAY_GROUP" -m 0700 "$gen"
install -o root -g "$RELAY_GROUP" -m 0640 "$SRC_CERT" "$gen/cert.pem"
install -o root -g "$RELAY_GROUP" -m 0640 "$SRC_KEY" "$gen/key.pem"
chmod 0750 "$gen"

current="$DEST_ROOT/current"
staged="$DEST_ROOT/current.next"
ln -sfn "$(basename "$gen")" "$staged"
# One rename. On failure current is untouched because we only move the staged link.
mv -fT "$staged" "$current"
# Stable names in this directory. The relay opens these, and moq watches this
# directory, so the rename of `current` above is the reload event.
ln -sfn "current/cert.pem" "$DEST_ROOT/cert.pem"
ln -sfn "current/key.pem" "$DEST_ROOT/key.pem"

# The running process serves the new generation to sessions opened after this
# rename. It is not restarted. A session opened before the rename stays up.
echo "relay-copy-cert: current -> $(basename "$gen")"
