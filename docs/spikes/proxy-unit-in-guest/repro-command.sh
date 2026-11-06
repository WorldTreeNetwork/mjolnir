#!/bin/bash
# Re-run the proxy-unit-in-guest spike against a local Mjolnir operator socket.
# Does not target a production host. Leaves the spawned guest for inspection.
set -euo pipefail
sock="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
src="${API_PROXY_SRC:-$HOME/work/IdentiKey/api-proxy}"
body='{"base_image":"ubuntu-24.04","memory_mb":1024,"vcpus":2,"restart_policy":"never","metadata":{"purpose":"proxy-unit-spike"}}'
id=$(sudo curl -sS --unix-socket "$sock" -H 'Content-Type: application/json' -X POST http://localhost/api/vms -d "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "spawned $id"
root="/var/lib/mjolnir/btrfs/@vms/$id"
sudo install -d "$root/usr/local/bin" "$root/etc/identikey-api-proxy" "$root/etc/systemd/system"
sudo cp -f "$src/target/release/identikey-api-proxy" "$root/usr/local/bin/identikey-api-proxy"
sudo chmod 755 "$root/usr/local/bin/identikey-api-proxy"
sudo cp -f "$src/deploy/identikey-api-proxy.service" "$root/etc/systemd/system/identikey-api-proxy.service"
sudo cp -f "$src/examples/registry.json" "$root/etc/identikey-api-proxy/registry.json"
guest() {
  sudo curl -sS --unix-socket "$sock" -H 'Content-Type: application/json' \
    -X POST "http://localhost/api/vms/$id/exec" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")"
  echo
}
guest 'systemctl daemon-reload && systemctl start identikey-api-proxy; systemctl is-active identikey-api-proxy; ls -ld /var/lib/identikey-api-proxy; journalctl -u identikey-api-proxy -n 20 --no-pager'
