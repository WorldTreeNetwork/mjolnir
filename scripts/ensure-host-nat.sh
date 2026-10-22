#!/bin/bash
# Keep guest egress masquerade across reboot.
#
# nftables.service is not the place for this. Arch's packaged
# nftables.conf is a drop-all input and forward policy. Loading it
# would black-hole guests and anything that is not ssh.
#
# When ufw is active, before.rules already owns the rule. This script
# leaves that alone.
#
# Usage (as root):
#   scripts/ensure-host-nat.sh
#   scripts/ensure-host-nat.sh --install-unit
set -euo pipefail

SUBNET="${MJOLNIR_VM_SUBNET:-10.200.0.0/10}"
INSTALL_UNIT=0
if [[ "${1:-}" == "--install-unit" ]]; then
    INSTALL_UNIT=1
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--install-unit]" >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root" >&2
    exit 1
fi

ufw_active() {
    command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'
}

rule_matches() {
    local shown="$1" subnet="$2"
    grep -F -- "-s ${subnet}" <<< "$shown" | grep -q -- '-j MASQUERADE'
}

nat_present() {
    # iptables stores 10.200.0.0/10 as 10.192.0.0/10. Match either form,
    # with or without an -o iface.
    local shown canon
    shown="$(iptables -t nat -S POSTROUTING 2>/dev/null || true)"
    if rule_matches "$shown" "$SUBNET"; then
        return 0
    fi
    if command -v python3 >/dev/null; then
        canon="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$SUBNET")"
        if [[ "$canon" != "$SUBNET" ]] && rule_matches "$shown" "$canon"; then
            return 0
        fi
    fi
    return 1
}

ensure_nat() {
    if ufw_active; then
        echo "ufw is active; NAT stays in before.rules"
        return 0
    fi
    if nat_present; then
        echo "guest masquerade already present for ${SUBNET}"
        return 0
    fi
    local iface
    iface="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
    if [[ -z "$iface" ]]; then
        echo "Error: no default route; cannot add masquerade" >&2
        return 1
    fi
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$iface" -j MASQUERADE
    echo "added masquerade for ${SUBNET} out ${iface}"
}

if [[ "$INSTALL_UNIT" -eq 1 ]]; then
    if ufw_active; then
        echo "ufw is active; not installing mjolnir-nat.service"
        exit 0
    fi
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    unit_src="$source_dir/../systemd/mjolnir-nat.service"
    if [[ ! -f "$unit_src" ]]; then
        echo "Error: missing $unit_src" >&2
        exit 1
    fi
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$source_dir/ensure-host-nat.sh" /usr/local/bin/mjolnir-ensure-host-nat
    install -m 0644 "$unit_src" /etc/systemd/system/mjolnir-nat.service
    systemctl daemon-reload
    systemctl enable mjolnir-nat.service
    systemctl restart mjolnir-nat.service
    echo "mjolnir-nat.service enabled"
else
    ensure_nat
fi
