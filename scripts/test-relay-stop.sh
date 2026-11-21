#!/usr/bin/env bash
# Laptop proof: SIGTERM drains, then the process exits.
# Throwaway certificate. Does not touch production.
set -euo pipefail
BIN="${1:?path to mjolnir-relay}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
echo '{"keys":[]}' >"$WORK/keys.json"
sudo chown root:root "$WORK/keys.json"
sudo chmod 644 "$WORK/keys.json"
sudo env \
    MJOLNIR_RELAY_HOST=localhost \
    MJOLNIR_RELAY_BIND=127.0.0.1:24443 \
    MJOLNIR_RELAY_TLS_DIR="$WORK" \
    MJOLNIR_RELAY_KEYS="$WORK/keys.json" \
    MJOLNIR_RELAY_KEYS_ACTIVE="$WORK/keys.active" \
    MJOLNIR_RELAY_STATE_DIR="$WORK/state" \
    MJOLNIR_RELAY_DRAIN_SECONDS=1 \
    "$BIN" >"$WORK/out" 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if sudo ss -lun | grep -q 24443; then
        break
    fi
    sleep 0.3
done
sudo kill -TERM "$pid"
# Drain is 1s. The process must exit. 15s is the bound in the stop scenario
# when drain is 1s (drain + ten seconds, with margin).
for _ in $(seq 1 30); do
    if ! sudo kill -0 "$pid" 2>/dev/null; then
        echo "sigterm: process exited"
        exit 0
    fi
    sleep 0.5
done
echo "sigterm: process still running" >&2
sudo kill -KILL "$pid" || true
exit 1
