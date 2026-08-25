#!/bin/bash
# Install mjolnir-redis on the Linux host. Does NOT restart Elixir.
#
# Usage (on the Mjolnir host, as root):
#   sudo bash scripts/install-redis.sh
#
# Binds 10.200.0.1:6379. Restarts the unit only when conf/unit/binary
# or password hash changed.

set -euo pipefail

ROOT="${MJOLNIR_CODE:-/opt/mjolnir}"
HOST_IP="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
VM_SUBNET="${MJOLNIR_VM_SUBNET:-10.192.0.0/10}"
UNIT_SRC="$ROOT/systemd/mjolnir-redis.service"
CONF_SRC="$ROOT/systemd/mjolnir-redis.conf"
UNIT_DST="/etc/systemd/system/mjolnir-redis.service"
CONF_DST="/etc/mjolnir/redis.conf"
PASS_FILE="/etc/mjolnir/redis.pass"
PASS_CONF="/etc/mjolnir/redis.pass.conf"
DATA_DIR="/var/lib/mjolnir/redis"
HASH_FILE="$DATA_DIR/.install-hash"
BIN="${REDIS_BIN:-/usr/bin/redis-server}"

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root" >&2
    exit 1
fi

if ! ip addr show dummy-mjolnir 2>/dev/null | grep -q "inet ${HOST_IP}/32"; then
    echo "Error: ${HOST_IP}/32 is not assigned on dummy-mjolnir. Fail closed." >&2
    exit 1
fi

echo "=== Installing redis-server package ==="
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null; then
    apt-get install -y redis-server
    systemctl disable --now redis-server 2>/dev/null || true
    systemctl mask redis-server 2>/dev/null || true
elif command -v pacman >/dev/null; then
    pacman -S --needed --noconfirm redis
    systemctl disable --now redis 2>/dev/null || true
    systemctl mask redis 2>/dev/null || true
    BIN="${REDIS_BIN:-/usr/bin/redis-server}"
else
    echo "Error: no apt-get or pacman" >&2
    exit 1
fi

if [[ ! -x "$BIN" ]]; then
    echo "Error: redis-server not at $BIN" >&2
    exit 1
fi

if ! id redis >/dev/null 2>&1; then
    echo "Error: redis user missing" >&2
    exit 1
fi

install -d -m 0750 -o redis -g redis "$DATA_DIR"
install -d -m 0755 /etc/mjolnir
install -d -m 0755 /usr/local/bin
install -m 0644 "$UNIT_SRC" "$UNIT_DST"

if [[ ! -s "$PASS_FILE" ]]; then
    umask 077
    openssl rand -base64 24 | tr -d '/+=' | head -c 32 > "$PASS_FILE"
    echo >> "$PASS_FILE"
    chmod 0600 "$PASS_FILE"
    echo "generated $PASS_FILE"
fi
PASS="$(tr -d '[:space:]' < "$PASS_FILE")"
umask 077
printf 'requirepass %s\n' "$PASS" > "$PASS_CONF"
chmod 0640 "$PASS_CONF"
chown root:redis "$PASS_CONF"
chown root:redis "$PASS_FILE" 2>/dev/null || chown root:root "$PASS_FILE"

{
    cat "$CONF_SRC"
    echo
    cat "$PASS_CONF"
} > "$CONF_DST"
chmod 0640 "$CONF_DST"
chown root:redis "$CONF_DST"

install -m 0755 "$ROOT/scripts/backup-redis-b2.sh" /usr/local/bin/backup-redis-b2.sh
if [[ -d "$ROOT/scripts/systemd" ]]; then
    install -m 0644 "$ROOT/scripts/systemd/mjolnir-redis-backup.service" /etc/systemd/system/mjolnir-redis-backup.service
    install -m 0644 "$ROOT/scripts/systemd/mjolnir-redis-backup.timer" /etc/systemd/system/mjolnir-redis-backup.timer
fi

echo "=== INPUT allow TAP → ${HOST_IP}:6379 ==="
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if ! ufw status | grep -q "${HOST_IP} 6379"; then
        ufw allow proto tcp from "$VM_SUBNET" to "$HOST_IP" port 6379 comment 'VMs to redis sidecar'
    fi
else
    if ! iptables -C INPUT -p tcp -s "$VM_SUBNET" -d "$HOST_IP" --dport 6379 -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -p tcp -s "$VM_SUBNET" -d "$HOST_IP" --dport 6379 -j ACCEPT
    fi
fi

NEW_HASH="$(
    {
        sha256sum "$UNIT_DST" "$CONF_DST" "$BIN"
        readlink -f "$BIN"
    } | sha256sum | awk '{print $1}'
)"
OLD_HASH=""
if [[ -f "$HASH_FILE" ]]; then
    OLD_HASH="$(cat "$HASH_FILE")"
fi

systemctl daemon-reload
systemctl enable mjolnir-redis

if [[ "$NEW_HASH" == "$OLD_HASH" ]] && systemctl is-active --quiet mjolnir-redis; then
    echo "=== redis unchanged (hash $NEW_HASH); not restarting ==="
else
    echo "=== systemd restart redis (Elixir untouched) ==="
    systemctl restart mjolnir-redis
    echo "$NEW_HASH" > "$HASH_FILE"
    chown redis:redis "$HASH_FILE"
fi

sleep 1
ss -lntp | grep 6379 || true
if ss -lntp | grep -q "0.0.0.0:6379"; then
    echo "Error: redis listening on 0.0.0.0" >&2
    exit 1
fi
if ! ss -lntp | grep -q "${HOST_IP}:6379"; then
    echo "Error: redis not listening on ${HOST_IP}:6379" >&2
    systemctl status mjolnir-redis --no-pager || true
    journalctl -u mjolnir-redis -n 40 --no-pager || true
    exit 1
fi
echo "=== redis sidecar installed ==="
