#!/bin/bash
# Install only the class boundary onto an explicitly supplied, offline image root.
# The caller supplies the proxy binary, registry, and stock service separately.
set -euo pipefail
[[ $# == 1 && -d "$1" ]] || { echo "Usage: $0 <proxy-image-root>" >&2; exit 1; }
root=$(realpath -- "$1")
[[ "$root" != / ]] || { echo "Refusing the host root" >&2; exit 1; }
# Refuse symlinked destination components: all writes must stay in this image.
for path in usr usr/local usr/local/bin usr/local/bin/mjolnir-network-setup etc etc/systemd etc/systemd/system etc/systemd/system/identikey-api-proxy.service.d etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf; do
  [[ ! -L "$root/$path" ]] || { echo "Refusing symlink: $path" >&2; exit 1; }
done
install -d "$root/usr/local/bin" "$root/etc/systemd/system/identikey-api-proxy.service.d"
cat > "$root/usr/local/bin/mjolnir-network-setup" <<'NETWORK'
#!/bin/bash
# mjolnir proxy guest network v1
set -euo pipefail
IP="${1:?Usage: mjolnir-network-setup <ip>}"
/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
while /sbin/ip route del default 2>/dev/null; do true; done
/sbin/ip route replace 10.200.0.1/32 dev eth0
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
echo "Network configured: $IP"
NETWORK
chmod 755 "$root/usr/local/bin/mjolnir-network-setup"
cat > "$root/etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/local/bin/identikey-api-proxy serve --config /etc/identikey-api-proxy/registry.json --data-dir /var/lib/private/identikey-api-proxy
WorkingDirectory=/var/lib/private/identikey-api-proxy
IPAddressAllow=10.200.0.1/32
UNIT
