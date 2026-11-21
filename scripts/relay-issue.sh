#!/usr/bin/env bash
# Operator-only issuance for the relay name.
# Not POST /api/certs/issue. Writes no [[domain]] and no route.
# The source directory is 0700 before any key byte, owned by the issuer user.
set -euo pipefail
HOST_NAME="${1:?relay host}"
EMAIL="${2:?acme email}"
SRC_ROOT="${3:-/var/lib/mjolnir/relay-acme}"
GATEWAY="${MJOLNIR_GATEWAY_BIN:-/usr/local/bin/mjolnir-gateway}"
DIR="$SRC_ROOT/$HOST_NAME"

[[ "$(id -u)" == 0 ]] || { echo "relay-issue: must run as root" >&2; exit 1; }
id mjolnir >/dev/null 2>&1 || { echo "relay-issue: user mjolnir is missing" >&2; exit 1; }

install -d -o mjolnir -g mjolnir -m 0700 "$SRC_ROOT"
if [[ -d "$DIR" ]]; then
    chown mjolnir:mjolnir "$DIR"
    chmod 0700 "$DIR"
else
    install -d -o mjolnir -g mjolnir -m 0700 "$DIR"
fi
mode="$(stat -c '%a' "$DIR")"
owner="$(stat -c '%u' "$DIR")"
[[ "$mode" == "700" && "$owner" == "$(id -u mjolnir)" ]] || {
    echo "relay-issue: $DIR is not a private issuer directory" >&2
    exit 1
}

# umask 077 so temporary files are private from creation.
systemd-run --quiet --wait --pipe --uid=mjolnir --gid=mjolnir \
    --property=UMask=0077 \
    "$GATEWAY" cert issue --domain "$HOST_NAME" --email "$EMAIL" --out "$DIR"

ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/relay-copy-cert.sh" "$DIR/fullchain.pem" "$DIR/privkey.pem" "$HOST_NAME"
