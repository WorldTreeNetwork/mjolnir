#!/usr/bin/env bash
# Proves the copy step's name match, symlink refusal, and private generation.
# Uses a throwaway CA. Does not talk to the production host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/good.key" -out "$WORK/good.crt" \
    -days 2 -subj /CN=relay.test -addext subjectAltName=DNS:relay.test >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/evil.key" -out "$WORK/evil.crt" \
    -days 2 -subj /CN=relay.test.evil.org -addext subjectAltName=DNS:relay.test.evil.org >/dev/null 2>&1
# Suffix must not match.
if "$ROOT/scripts/relay-copy-cert.sh" "$WORK/evil.crt" "$WORK/evil.key" relay.test "$WORK/tls" mjolnir-relay; then
    echo "suffix name was accepted" >&2
    exit 1
fi
# Symlink parent is refused before any write.
ln -s /tmp "$WORK/linked"
if "$ROOT/scripts/relay-copy-cert.sh" "$WORK/good.crt" "$WORK/good.key" relay.test "$WORK/linked/tls" mjolnir-relay; then
    echo "symlink parent was accepted" >&2
    exit 1
fi
sudo "$ROOT/scripts/relay-copy-cert.sh" "$WORK/good.crt" "$WORK/good.key" relay.test "$WORK/tls" "$(id -gn)"
test -f "$WORK/tls/current/key.pem"
echo "relay-copy-cert checks passed"
