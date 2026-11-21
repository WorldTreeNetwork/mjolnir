#!/usr/bin/env bash
# Runs on the host, as root, from a staged tree. Reads /etc/mjolnir/env.
# Enabled + host + a pair that the unit can start: install, start, then one
# UDP 443 rule tagged mjolnir-relay. Otherwise stop and remove both.
set -euo pipefail
STAGED="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/mjolnir/env
enabled=false
host_name=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
    [[ "${MJOLNIR_RELAY_ENABLED:-}" == "true" ]] && enabled=true
    host_name="${MJOLNIR_RELAY_HOST:-}"
fi

rule_present() {
    iptables -S INPUT 2>/dev/null | grep -q -- '--comment mjolnir-relay'
}
remove_rule() {
    while iptables -S INPUT 2>/dev/null | grep -q -- '--comment mjolnir-relay'; do
        local spec
        spec="$(iptables -S INPUT | grep -- '--comment mjolnir-relay' | head -1 | sed 's/^-A /-D /')"
        # shellcheck disable=SC2086
        iptables $spec
    done
}
stop_and_remove() {
    systemctl disable --now mjolnir-relay >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mjolnir-relay.service
    systemctl daemon-reload
    remove_rule
}

if ! $enabled || [[ -z "$host_name" ]]; then
    stop_and_remove
    exit 0
fi

id mjolnir-relay >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/mjolnir-relay-state --shell /usr/sbin/nologin mjolnir-relay
install -d -o root -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay /var/lib/mjolnir-relay/tls
install -d -o mjolnir-relay -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay-state
install -m 0755 "$STAGED/native/mjolnir_relay/target/release/mjolnir-relay" /usr/local/bin/mjolnir-relay
install -m 0644 "$STAGED/systemd/mjolnir-relay.service" /etc/systemd/system/mjolnir-relay.service
systemctl daemon-reload
systemctl enable mjolnir-relay
if ! systemctl restart mjolnir-relay; then
    remove_rule
    exit 1
fi
if ! systemctl is-active --quiet mjolnir-relay; then
    remove_rule
    exit 1
fi
if ! rule_present; then
    iptables -I INPUT -p udp --dport 443 -m comment --comment mjolnir-relay -j ACCEPT
fi
