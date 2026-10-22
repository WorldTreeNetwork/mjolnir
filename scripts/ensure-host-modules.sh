#!/bin/bash
# Write /etc/modules-load.d/mjolnir.conf so the next boot loads the modules
# the fabric and sidecars need: kvm, tun, vhost_vsock, dummy, NAT.
#
# If the running kernel has no /lib/modules tree (linux was upgraded and
# the machine has not rebooted), the file targets the installed tree.
# This script does not reboot.
#
# Usage (as root):
#   scripts/ensure-host-modules.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root" >&2
    exit 1
fi

module_present() {
    local kver="$1" name="$2" alt base
    alt="${name//_/-}"
    base="/lib/modules/${kver}"
    [[ -d "$base" ]] || return 1
    find "$base" -type f \( \
        -name "${name}.ko" -o -name "${name}.ko.zst" -o -name "${name}.ko.xz" -o -name "${name}.ko.gz" \
        -o -name "${alt}.ko" -o -name "${alt}.ko.zst" -o -name "${alt}.ko.xz" -o -name "${alt}.ko.gz" \
    \) -print -quit | grep -q .
}

running="$(uname -r)"
if [[ -d "/lib/modules/${running}" ]]; then
    kver="$running"
else
    shopt -s nullglob
    trees=(/lib/modules/*)
    shopt -u nullglob
    if [[ ${#trees[@]} -eq 0 ]]; then
        echo "Error: no /lib/modules tree. Install the linux package." >&2
        exit 1
    fi
    kver="$(basename "$(printf '%s\n' "${trees[@]}" | sort -V | tail -1)")"
    echo "Running kernel ${running} has no modules. modules-load.d targets ${kver} for the next boot."
fi

vendor=""
if [[ -r /proc/cpuinfo ]] && grep -q AuthenticAMD /proc/cpuinfo; then
    vendor="kvm_amd"
elif [[ -r /proc/cpuinfo ]] && grep -q GenuineIntel /proc/cpuinfo; then
    vendor="kvm_intel"
fi
if [[ -n "$vendor" ]] && ! module_present "$kver" "$vendor"; then
    vendor=""
fi
if [[ -z "$vendor" ]]; then
    if module_present "$kver" kvm_amd; then
        vendor="kvm_amd"
    elif module_present "$kver" kvm_intel; then
        vendor="kvm_intel"
    fi
fi

wanted=(kvm tun vhost_vsock dummy nf_nat nft_masq xt_MASQUERADE xt_tcpudp)
if [[ -n "$vendor" ]]; then
    wanted+=( "$vendor" )
fi

selected=()
for name in "${wanted[@]}"; do
    if module_present "$kver" "$name"; then
        selected+=( "$name" )
    fi
done

if [[ ${#selected[@]} -eq 0 ]]; then
    echo "Error: none of the Mjolnir modules are in /lib/modules/${kver}." >&2
    exit 1
fi

install -d -m 0755 /etc/modules-load.d
tmp="$(mktemp)"
{
    echo "# Mjolnir host modules. Written by scripts/ensure-host-modules.sh."
    printf '%s\n' "${selected[@]}"
} > "$tmp"
install -m 0644 "$tmp" /etc/modules-load.d/mjolnir.conf
rm -f "$tmp"
echo "wrote /etc/modules-load.d/mjolnir.conf for ${kver}: ${selected[*]}"

if [[ "$kver" == "$running" ]]; then
    for name in "${selected[@]}"; do
        modprobe "$name" 2>/dev/null || echo "warning: modprobe ${name} failed" >&2
    done
fi
