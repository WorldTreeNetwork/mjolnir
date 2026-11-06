#!/bin/bash
# Re-run the proxy-guest-class boot spike on the local operator socket.
# Creates a throwaway @base snapshot, spawns it with enable_iroh false, prints
# exec output, then deletes the guest and the throwaway base.
# Does not print the spawn body. Does not restart mjolnir. Does not edit @base/ubuntu-24.04.
set -euo pipefail
sock="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
src="${API_PROXY_SRC:-$HOME/work/IdentiKey/api-proxy}"
name="proxy-guest-class-spike"
base="/var/lib/mjolnir/btrfs/@base/$name"
sudo btrfs subvolume snapshot "/var/lib/mjolnir/btrfs/@base/ubuntu-24.04" "$base"
sudo tee "$base/usr/local/bin/mjolnir-network-setup" >/dev/null <<'EOF'
#!/bin/bash
set -e
IP="$1"
if [[ -z "$IP" ]]; then
    echo "Usage: mjolnir-network-setup <ip>" >&2
    exit 1
fi
/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
while /sbin/ip route del default 2>/dev/null; do
    true
done
/sbin/ip route replace 10.200.0.1/32 dev eth0
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
echo "Network configured: $IP"
EOF
sudo chmod 755 "$base/usr/local/bin/mjolnir-network-setup"
sudo install -d "$base/etc/identikey-api-proxy" \
  "$base/etc/systemd/system/identikey-api-proxy.service.d" \
  "$base/etc/systemd/system/multi-user.target.wants"
sudo cp -f "$src/target/release/identikey-api-proxy" "$base/usr/local/bin/identikey-api-proxy"
sudo chmod 755 "$base/usr/local/bin/identikey-api-proxy"
sudo cp -f "$src/deploy/identikey-api-proxy.service" "$base/etc/systemd/system/identikey-api-proxy.service"
sudo cp -f "$src/examples/registry.json" "$base/etc/identikey-api-proxy/registry.json"
sudo tee "$base/etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/identikey-api-proxy serve --config /etc/identikey-api-proxy/registry.json --data-dir /var/lib/private/identikey-api-proxy
WorkingDirectory=/var/lib/private/identikey-api-proxy
IPAddressAllow=10.200.0.1/32
EOF
sudo ln -sfn ../identikey-api-proxy.service "$base/etc/systemd/system/multi-user.target.wants/identikey-api-proxy.service"
id=$(sudo curl -sS -m 120 --unix-socket "$sock" -H 'Content-Type: application/json' -X POST http://localhost/api/vms \
  -d "{\"base_image\":\"$name\",\"memory_mb\":1024,\"vcpus\":2,\"restart_policy\":\"never\",\"enable_iroh\":false}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "spawned $id"
sudo curl -sS -m 60 --unix-socket "$sock" -H 'Content-Type: application/json' \
  -X POST "http://localhost/api/vms/$id/exec" \
  -d '{"command":"ip route; echo ---; cat /etc/resolv.conf; echo ---; systemctl is-active identikey-api-proxy"}'
echo
sudo curl -sS -m 30 --unix-socket "$sock" -X DELETE "http://localhost/api/vms/$id" >/dev/null
sudo btrfs subvolume delete "$base"
echo "deleted $id and $name"
