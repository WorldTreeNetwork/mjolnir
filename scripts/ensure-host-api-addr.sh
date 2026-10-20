#!/bin/bash
# Assign the reserved host-from-guest address on dummy-mjolnir.
#
# TAP guests use a /32. They ARP the host. An address that lives only on lo
# is invisible to them, and rp_filter drops the reply. Never fall back to lo.
#
# Usage (as root):
#   scripts/ensure-host-api-addr.sh
#   scripts/ensure-host-api-addr.sh --install-unit
#
# --install-unit copies this script to /usr/local/bin/mjolnir-ensure-host-api-addr
# and enables mjolnir-hotel-ip.service so a reboot recreates the address
# before Redis, the blob door, and the BEAM.
set -euo pipefail

HOST_IP="${MJOLNIR_HOST_API_IP:-10.200.0.1}"
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

assign_host_api_addr() {
    if ip addr show dummy-mjolnir 2>/dev/null | grep -q "inet ${HOST_IP}/32"; then
        echo "host api ${HOST_IP}/32 already on dummy-mjolnir"
        return 0
    fi

    # Built-in dummy has nothing for modprobe to load. A missing module is
    # reported by `ip link add` below, not by this probe.
    modprobe dummy 2>/dev/null || true

    if ! ip link show dummy-mjolnir >/dev/null 2>&1; then
        if ! ip link add dummy-mjolnir type dummy; then
            echo "Error: cannot create dummy-mjolnir (dummy.ko is not loaded for the running kernel)." >&2
            echo "Refusing to assign ${HOST_IP}/32 on lo. Guests cannot ARP loopback." >&2
            return 1
        fi
    fi
    ip link set dummy-mjolnir up

    # A previous bootstrap may have parked the address on lo. Move it.
    if ip addr show lo | grep -q "inet ${HOST_IP}/32"; then
        ip addr del "${HOST_IP}/32" dev lo || true
    fi
    ip addr replace "${HOST_IP}/32" dev dummy-mjolnir

    if ! ip addr show dummy-mjolnir | grep -q "inet ${HOST_IP}/32"; then
        echo "Error: failed to assign ${HOST_IP}/32 on dummy-mjolnir" >&2
        return 1
    fi
    echo "assigned ${HOST_IP}/32 on dummy-mjolnir"
}

if [[ "$INSTALL_UNIT" -eq 1 ]]; then
    # Install the unit before assigning. A kernel with no dummy.ko still
    # gets a boot-time retry, and this script does not put the address on lo.
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    unit_src="$source_dir/../systemd/mjolnir-hotel-ip.service"
    if [[ ! -f "$unit_src" ]]; then
        echo "Error: missing $unit_src" >&2
        exit 1
    fi
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$source_dir/ensure-host-api-addr.sh" /usr/local/bin/mjolnir-ensure-host-api-addr
    install -m 0644 "$unit_src" /etc/systemd/system/mjolnir-hotel-ip.service
    systemctl daemon-reload
    systemctl enable mjolnir-hotel-ip.service
    # restart, not start: an older RemainAfterExit oneshot of the same name
    # stays active and would not re-run the new ExecStart.
    systemctl restart mjolnir-hotel-ip.service
    echo "mjolnir-hotel-ip.service enabled"
else
    assign_host_api_addr
fi
