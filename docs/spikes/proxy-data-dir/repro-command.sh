#!/bin/bash
# Re-run the proxy-data-dir spike on the local operator socket.
# Prints the guest id and exec output. Does not print the spawn body (it carries an Iroh ticket).
# Deletes the throwaway guest at the end. Does not restart mjolnir.
set -euo pipefail
sock="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
src="${API_PROXY_SRC:-$HOME/work/IdentiKey/api-proxy}"
body='{"base_image":"ubuntu-24.04","memory_mb":1024,"vcpus":2,"restart_policy":"never","metadata":{"purpose":"proxy-data-dir-spike"}}'
id=$(sudo curl -sS -m 120 --unix-socket "$sock" -H 'Content-Type: application/json' -X POST http://localhost/api/vms -d "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "spawned $id"
root="/var/lib/mjolnir/btrfs/@vms/$id"
sudo install -d "$root/usr/local/bin" "$root/etc/identikey-api-proxy" \
  "$root/etc/systemd/system/identikey-api-proxy.service.d" \
  "$root/usr/local/lib/mjolnir-spike"
sudo cp -f "$src/target/release/identikey-api-proxy" "$root/usr/local/bin/identikey-api-proxy"
sudo chmod 755 "$root/usr/local/bin/identikey-api-proxy"
sudo cp -f "$src/deploy/identikey-api-proxy.service" "$root/etc/systemd/system/identikey-api-proxy.service"
sudo cp -f "$src/examples/registry.json" "$root/etc/identikey-api-proxy/registry.json"
sudo tee "$root/etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/identikey-api-proxy serve --config /etc/identikey-api-proxy/registry.json --data-dir /var/lib/private/identikey-api-proxy
WorkingDirectory=/var/lib/private/identikey-api-proxy
IPAddressAllow=10.200.0.1/32
EOF
sudo tee "$root/usr/local/lib/mjolnir-spike/probe.sh" >/dev/null <<'EOF'
#!/bin/bash
set +e
systemctl daemon-reload
systemctl start identikey-api-proxy
sleep 2
echo "active=$(systemctl is-active identikey-api-proxy)"
stat -c '%F %a %N' /var/lib/identikey-api-proxy /var/lib/private/identikey-api-proxy
ss -ltnp | grep 8787 || echo NO_LISTEN
try() {
  local label="$1" host="$2" port="$3"
  if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}"; then echo "$label OK"; else echo "$label FAIL"; fi
}
echo "=== root ==="
try ROOT_LOOP 127.0.0.1 8787
try ROOT_HOST 10.200.0.1 4000
try ROOT_PUB 1.1.1.1 443
cg=$(systemctl show -p ControlGroup --value identikey-api-proxy.service)
if echo $$ > "/sys/fs/cgroup${cg}/cgroup.procs"; then echo joined; else echo join-failed; exit 0; fi
try UNIT_LOOP 127.0.0.1 8787
try UNIT_HOST 10.200.0.1 4000
try UNIT_PUB 1.1.1.1 443
EOF
sudo chmod 755 "$root/usr/local/lib/mjolnir-spike/probe.sh"
sudo curl -sS -m 90 --unix-socket "$sock" -H 'Content-Type: application/json' \
  -X POST "http://localhost/api/vms/$id/exec" \
  -d '{"command":"/usr/local/lib/mjolnir-spike/probe.sh"}'
echo
echo "delete $id"
sudo curl -sS -m 30 --unix-socket "$sock" -X DELETE "http://localhost/api/vms/$id"
echo
