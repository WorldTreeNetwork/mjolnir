#!/usr/bin/env bash
# Runs on the host, as root, from a staged tree. Does not read /etc/mjolnir/env.
# Enabled + host + a pair that the unit can start: install scripts, start.
# The unit owns the one UDP 443 rule tagged mjolnir-relay.
# The renew timer is separate from the controller cert timer.
# Otherwise stop and remove the unit, the timer, and the rule.
set -euo pipefail
STAGED="$(cd "$(dirname "$0")/.." && pwd)"
# The controller file holds secrets. The relay unit never sees it.
# Enablement is read here, as root. The relay's files live in
# /etc/mjolnir-relay, which the gateway user cannot write. An older
# install under /etc/mjolnir is moved once.
CONF=/etc/mjolnir-relay
install -d -o root -g root -m 0755 "$CONF"
if [[ -f /etc/mjolnir/relay.env && ! -e $CONF/relay.env ]]; then
    mv -f /etc/mjolnir/relay.env "$CONF/relay.env"
fi
if [[ -f /etc/mjolnir/relay-keys.json && ! -e $CONF/relay-keys.json ]]; then
    mv -f /etc/mjolnir/relay-keys.json "$CONF/relay-keys.json"
fi
if [[ -f $CONF/relay.env ]]; then
    chown root:root "$CONF/relay.env"
    chmod 0640 "$CONF/relay.env"
fi
if [[ -f $CONF/relay-keys.json ]]; then
    chown root:root "$CONF/relay-keys.json"
    chmod 0644 "$CONF/relay-keys.json"
fi
ENV_FILE=$CONF/relay.env
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

# The relay user has to exist before relay-issue.sh copies a certificate.
# A disabled deploy does not install a unit. The user is inert until one does.
if ! id mjolnir-relay >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/mjolnir-relay-state --shell /usr/sbin/nologin mjolnir-relay
fi
install -d -o root -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay /var/lib/mjolnir-relay/tls
install -d -o mjolnir-relay -g mjolnir-relay -m 0750 /var/lib/mjolnir-relay-state

if ! $enabled || [[ -z "$host_name" ]]; then
    stop_and_remove
    exit 0
fi
# A directory owner can replace the key file. Only root may write this one.
conf_mode="$(stat -c '%a' "$CONF")"
conf_owner="$(stat -c '%u' "$CONF")"
conf_group="${conf_mode: -2:1}"
conf_other="${conf_mode: -1}"
if [[ "$conf_owner" != 0 || "$conf_group" == 2 || "$conf_group" == 3 || "$conf_group" == 6 || "$conf_group" == 7 || "$conf_other" == 2 || "$conf_other" == 3 || "$conf_other" == 6 || "$conf_other" == 7 ]]; then
    echo "relay-deploy: $CONF must be root-owned and not writable by group or other" >&2
    exit 1
fi
# An issue that already succeeded leaves the pair here. Copy it before
# the unit starts, including when the previous copy failed.
issued="/var/lib/mjolnir/relay-acme/${host_name}/fullchain.pem"
issued_key="/var/lib/mjolnir/relay-acme/${host_name}/privkey.pem"
if [[ -f "$issued" && -f "$issued_key" ]]; then
    "$LIB/relay-copy-cert.sh" "$issued" "$issued_key" "$host_name"
fi
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
