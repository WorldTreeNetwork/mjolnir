#!/usr/bin/env bash
# Daily hook from mjolnir-cert-renew.service.
# Reads /etc/mjolnir/relay.env only. No controller secrets.
# No-ops when the relay is not configured. Does not edit gateway routes.
set -euo pipefail
ENV_FILE=/etc/mjolnir/relay.env
[[ -f "$ENV_FILE" ]] || exit 0
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
[[ "${MJOLNIR_RELAY_ENABLED:-}" == "true" && -n "${MJOLNIR_RELAY_HOST:-}" ]] || exit 0
[[ -n "${MJOLNIR_RELAY_ACME_EMAIL:-}" ]] || {
    echo "relay-renew: MJOLNIR_RELAY_ACME_EMAIL is unset" >&2
    exit 1
}
CERT=/var/lib/mjolnir-relay/tls/current/cert.pem
if [[ -f "$CERT" ]] && openssl x509 -in "$CERT" -noout -checkend $((30 * 24 * 3600)) >/dev/null 2>&1; then
    exit 0
fi
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/relay-issue.sh" "$MJOLNIR_RELAY_HOST" "$MJOLNIR_RELAY_ACME_EMAIL"
