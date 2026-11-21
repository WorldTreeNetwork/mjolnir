#!/usr/bin/env bash
# Runs on the host, as root, from a staged tree. Reads /etc/mjolnir/env.
# Enabled + host + a pair that the unit can start: install scripts, start.
# The unit owns the one UDP 443 rule tagged mjolnir-relay.
# The renew timer is separate from the controller cert timer.
# Otherwise stop and remove the unit, the timer, and the rule.
set -euo pipefail
STAGED="$(cd "$(dirname "$0")/.." && pwd)"
# The controller file holds secrets. The relay unit never sees it.
# Enablement is read here, as root, and only MJOLNIR_RELAY_* is written
# into /etc/mjolnir/relay.env for the unit.
ENV_FILE=/etc/mjolnir/relay.env
enabled=false
host_name=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
    [[ "${MJOLNIR_RELAY_ENABLED:-}" == "true" ]] && enabled=true
    host_name="${MJOLNIR_RELAY_HOST:-}"
fi

LIB=/usr/local/lib/mjolnir-relay
install -d -o root -g root -m 0755 "$LIB"
install -m 0755 \
    "$STAGED/scripts/relay-rule.sh" \
    "$STAGED/scripts/relay-renew.sh" \
    "$STAGED/scripts/relay-issue.sh" \
    "$STAGED/scripts/relay-copy-cert.sh" \
    "$LIB/"

remove_rule() {
    if [[ -x "$LIB/relay-rule.sh" ]]; then
        "$LIB/relay-rule.sh" del
        return
    fi
    while iptables -S INPUT 2>/dev/null | grep -q -- '--comment mjolnir-relay'; do
        local spec
        spec="$(iptables -S INPUT | grep -- '--comment mjolnir-relay' | head -1 | sed 's/^-A /-D /')"
        # shellcheck disable=SC2086
        iptables $spec
    done
}
stop_and_remove() {
    systemctl disable --now mjolnir-relay-renew.timer >/dev/null 2>&1 || true
    systemctl disable --now mjolnir-relay >/dev/null 2>&1 || true
    rm -f \
        /etc/systemd/system/mjolnir-relay.service \
        /etc/systemd/system/mjolnir-relay-renew.service \
        /etc/systemd/system/mjolnir-relay-renew.timer
    systemctl daemon-reload
    remove_rule
}

if ! $enabled || [[ -z "$host_name" ]]; then
    stop_and_remove
    exit 0
fi

id mjolnir-relay >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mjolnir-relay-state --shell /usr/sbin/nologin mjolnir-relay
install -d -o root -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay /var/lib/mjolnir-relay/tls
install -d -o root -g root -m 0755 /etc/mjolnir
if [[ -f /etc/mjolnir/relay-keys.json ]]; then
    chown root:root /etc/mjolnir/relay-keys.json
    chmod 0644 /etc/mjolnir/relay-keys.json
fi
install -d -o mjolnir-relay -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay-state
install -m 0755 "$STAGED/native/mjolnir_relay/target/release/mjolnir-relay" /usr/local/bin/mjolnir-relay
install -m 0644 "$STAGED/systemd/mjolnir-relay.service" /etc/systemd/system/mjolnir-relay.service
install -m 0644 "$STAGED/systemd/mjolnir-relay-renew.service" /etc/systemd/system/mjolnir-relay-renew.service
install -m 0644 "$STAGED/systemd/mjolnir-relay-renew.timer" /etc/systemd/system/mjolnir-relay-renew.timer
systemctl daemon-reload
systemctl enable mjolnir-relay
# The unit adds the UDP 443 rule in ExecStartPost and removes it in
# ExecStopPost. A failed start must not leave the rule or the renew timer.
if ! systemctl restart mjolnir-relay; then
    systemctl disable --now mjolnir-relay-renew.timer >/dev/null 2>&1 || true
    remove_rule
    exit 1
fi
sleep 1
if ! systemctl is-active --quiet mjolnir-relay; then
    systemctl disable --now mjolnir-relay-renew.timer >/dev/null 2>&1 || true
    remove_rule
    exit 1
fi
systemctl enable --now mjolnir-relay-renew.timer
