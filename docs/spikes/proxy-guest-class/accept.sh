#!/bin/bash
# Local acceptance for the proxy guest class. Exits non-zero on any failed assertion.
# Throwaway base and guests only. Does not edit @base/ubuntu-24.04 or restart mjolnir.
set -euo pipefail
sock="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
src="${API_PROXY_SRC:-$HOME/work/IdentiKey/api-proxy}"
name="proxy-guest-class-spike"
base="/var/lib/mjolnir/btrfs/@base/$name"
fail() { echo "FAIL $*" >&2; exit 1; }
say() { echo "OK $*"; }
v6_pid=""
tap=""
protected_id="13daU4EVEt41Z3CDxLEgkA"
here=$(cd "$(dirname "$0")" && pwd)
check="$here/accept_check.py"
run_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
python3 "$check" fixtures

cleanup() {
  if [[ -n "${v6_pid:-}" ]]; then
    kill "$v6_pid" 2>/dev/null || true
  fi
  if [[ -n "${tap:-}" ]]; then
    sudo ip -6 addr del fd00:86::1/64 dev "$tap" 2>/dev/null || true
  fi
  if [[ -n "${proxy_id:-}" ]]; then
    delete_vm "$proxy_id"
  fi
  if [[ -n "${ordinary_id:-}" ]]; then
    delete_vm "$ordinary_id"
  fi
  if sudo btrfs subvolume list /var/lib/mjolnir/btrfs | grep -q "@base/$name$"; then
    sudo btrfs subvolume delete "$base" >/dev/null || true
  fi
}
trap cleanup EXIT

if sudo btrfs subvolume list /var/lib/mjolnir/btrfs | grep -q "@base/$name$"; then
  sudo btrfs subvolume delete "$base"
fi
[[ -x "$src/target/release/identikey-api-proxy" ]] || fail "missing api-proxy release binary"
sudo btrfs subvolume snapshot /var/lib/mjolnir/btrfs/@base/ubuntu-24.04 "$base"
# The stock image disables IPv6. The throwaway proxy image turns it on so the
# confinement probe can open a real non-loopback IPv6 target. ubuntu-24.04 is unchanged.
sudo rm -f "$base/etc/sysctl.d/99-disable-ipv6.conf"
sudo tee "$base/etc/sysctl.d/99-enable-ipv6.conf" >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.eth0.disable_ipv6 = 0
EOF
sudo tee "$base/usr/local/bin/mjolnir-network-setup" >/dev/null <<'EOF'
#!/bin/bash
set -e
IP="$1"
[[ -n "$IP" ]] || { echo "Usage: mjolnir-network-setup <ip>" >&2; exit 1; }
/sbin/ip addr add "${IP}/32" dev eth0 2>/dev/null || true
/sbin/ip link set eth0 up
while /sbin/ip route del default 2>/dev/null; do true; done
/sbin/ip route replace 10.200.0.1/32 dev eth0
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
echo "Network configured: $IP"
EOF
sudo chmod 755 "$base/usr/local/bin/mjolnir-network-setup"
sudo install -d "$base/etc/identikey-api-proxy" \
  "$base/etc/systemd/system/identikey-api-proxy.service.d" \
  "$base/etc/systemd/system/multi-user.target.wants" \
  "$base/usr/local/lib/mjolnir-spike"
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
sudo tee "$base/usr/local/lib/mjolnir-spike/probe.sh" >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
try() {
  local label="$1" host="$2" port="$3"
  if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}"; then echo "$label OK"; else echo "$label FAIL"; fi
}
try6() {
  local label="$1" host="$2" port="$3" code=0
  # Bash /dev/tcp has no IPv6. Curl 52 (empty reply) means the TCP open worked.
  timeout 3 curl -g -6 -sS -o /dev/null --connect-timeout 3 "http://[${host}]:${port}/" || code=$?
  if [[ "$code" -eq 0 || "$code" -eq 52 ]]; then echo "$label OK"; else echo "$label FAIL"; fi
}
echo "=== root ==="
try ROOT_LOOP 127.0.0.1 8787
try ROOT_HOST 10.200.0.1 4000
try ROOT_PUB 1.1.1.1 443
try ROOT_ALT 9.9.9.9 443
try6 ROOT_V6 fd00:86::1 18787
cg=$(systemctl show -p ControlGroup --value identikey-api-proxy.service)
if [[ -z "$cg" ]]; then echo "NO_CGROUP"; exit 0; fi
if ! echo $$ > "/sys/fs/cgroup${cg}/cgroup.procs"; then echo "JOIN_FAIL"; exit 0; fi
echo joined
try UNIT_LOOP 127.0.0.1 8787
try UNIT_HOST 10.200.0.1 4000
try UNIT_PUB 1.1.1.1 443
try UNIT_ALT 9.9.9.9 443
try6 UNIT_V6 fd00:86::1 18787
exit 0
EOF
sudo chmod 755 "$base/usr/local/lib/mjolnir-spike/probe.sh"

vm_ids() {
  sudo curl -sS -m 15 --unix-socket "$sock" http://localhost/api/vms \
    | python3 -c 'import json,sys
for v in json.load(sys.stdin).get("vms") or []:
    i=v.get("id")
    if i: print(i)'
}
owned_id() {
  local id="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if python3 "$check" owned "/var/lib/mjolnir/state/$id.json" "$run_id"; then
      return 0
    fi
    sleep 0.3
  done
  return 1
}
delete_vm() {
  local id="$1" vol
  [[ -n "$id" && "$id" != "$protected_id" ]] || return 0
  if ! owned_id "$id"; then
    echo "skip unowned $id" >&2
    return 0
  fi
  sudo curl -sS -m 30 --unix-socket "$sock" -X DELETE "http://localhost/api/vms/$id" >/dev/null || true
  vol="/var/lib/mjolnir/btrfs/@vms/$id"
  if sudo btrfs subvolume list /var/lib/mjolnir/btrfs | grep -q "@vms/$id$"; then
    sudo btrfs subvolume delete "$vol" >/dev/null || true
  fi
  sudo rm -f "/var/lib/mjolnir/state/$id.json"
}
# Writes the spawn body to $2 and prints the id. Retries a guest-agent timeout.
# The body stays on disk so the caller can assert fields without putting it in argv.
spawn() {
  local payload="$1" bodyf="$2" attempt before after id reason nid
  : >"$bodyf"
  chmod 600 "$bodyf"
  for attempt in 1 2 3; do
    before=$(vm_ids | sort)
    sudo curl -sS -m 120 --unix-socket "$sock" -H 'Content-Type: application/json' \
      -X POST http://localhost/api/vms -d "$payload" >"$bodyf"
    id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id") or "")' "$bodyf")
    if [[ -n "$id" && "$id" != "$protected_id" ]]; then
      echo "$id"
      return 0
    fi
    reason=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("reason") or d.get("error") or "no-id")' "$bodyf")
    after=$(vm_ids | sort)
    while read -r nid; do
      [[ -n "$nid" ]] || continue
      # List difference is not ownership. delete_vm checks accept_run.
      delete_vm "$nid"
    done < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
    echo "spawn attempt $attempt failed: $reason" >&2
    sleep 2
  done
  return 1
}
guest_file() {
  local id="$1" cmd="$2" dest="$3"
  sudo curl -sS -m 90 --unix-socket "$sock" -H 'Content-Type: application/json' \
    -X POST "http://localhost/api/vms/$id/exec" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$cmd")" >"$dest"
}

proxy_body=$(mktemp)
chmod 600 "$proxy_body"
proxy_id=$(spawn "$(python3 "$check" payload proxy "$run_id")" "$proxy_body") \
  || fail "proxy spawn"
python3 "$check" spawn "$proxy_body"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("proxy", d.get("id"), d.get("guest_ip"))' "$proxy_body"
rm -f "$proxy_body"
say "proxy spawned without a relay"

bootf=$(mktemp)
guest_file "$proxy_id" 'ip route; echo ---; cat /etc/resolv.conf; echo ---; systemctl is-active identikey-api-proxy' "$bootf"
python3 "$check" pin "$bootf"
rm -f "$bootf"
say "boot pin"

# Reachable IPv6 is a throwaway address on this guest's TAP only.
tap="mj-${proxy_id:0:8}"
ip link show "$tap" >/dev/null
sudo ip -6 addr replace fd00:86::1/64 dev "$tap" nodad
rm -f /tmp/proxy-v6-listen.ready
python3 - <<'PY' &
import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("fd00:86::1", 18787))
s.listen(8)
open("/tmp/proxy-v6-listen.ready", "w").write("ok")
s.settimeout(600)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        break
PY
v6_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f /tmp/proxy-v6-listen.ready ]] && break
  sleep 0.2
done
[[ -f /tmp/proxy-v6-listen.ready ]] || fail "ipv6 listener did not bind"

# Plant a default route. Root must open public targets. The unit must not.
plantf=$(mktemp)
guest_file "$proxy_id" 'sysctl -w net.ipv6.conf.all.disable_ipv6=0; sysctl -w net.ipv6.conf.eth0.disable_ipv6=0; ip route add default dev eth0; ip -6 addr add fd00:86::2/64 dev eth0 nodad; ip route; echo ---; /usr/local/lib/mjolnir-spike/probe.sh' "$plantf"
python3 "$check" confinement "$plantf"
rm -f "$plantf"
say "confinement while a default route exists"

# The running release treats a default route as healthy. Remove it and the host
# /32 so GuestNetwork is dead, then require the level-2 heal to restore the pin.
wipedf=$(mktemp)
guest_file "$proxy_id" 'while ip route del default 2>/dev/null; do true; done; ip route del 10.200.0.1/32 2>/dev/null || true; ip route' "$wipedf"
python3 "$check" wiped "$wipedf"
rm -f "$wipedf"
say "routes removed before heal"
healf=$(mktemp)
sudo curl -sS -m 90 --unix-socket "$sock" -H 'Content-Type: application/json' \
  -X POST "http://localhost/api/vms/$proxy_id/heal" -d '{"max_level":2}' >"$healf"
python3 "$check" heal "$healf"
rm -f "$healf"
afterf=$(mktemp)
guest_file "$proxy_id" 'ip route; echo ---; cat /etc/resolv.conf; echo ---; systemctl is-active identikey-api-proxy' "$afterf"
python3 "$check" pin "$afterf"
rm -f "$afterf"
say "level-2 heal restored the pin"

python3 "$check" state "/var/lib/mjolnir/state/$proxy_id.json" "$proxy_id" "$name" "$run_id"
say "stored base_image and enable_iroh false"

rebootf=$(mktemp)
chmod 600 "$rebootf"
sudo curl -sS -m 150 --unix-socket "$sock" -H 'Content-Type: application/json' \
  -X POST "http://localhost/api/vms/$proxy_id/reboot" -d '{}' >"$rebootf"
python3 "$check" reboot "$rebootf"
rm -f "$rebootf"
livef=$(mktemp)
chmod 600 "$livef"
sudo curl -sS -m 30 --unix-socket "$sock" "http://localhost/api/vms/$proxy_id" >"$livef"
python3 "$check" live "$livef" "$proxy_id"
rm -f "$livef"
resumef=$(mktemp)
guest_file "$proxy_id" 'ip route; echo ---; cat /etc/resolv.conf; echo ---; systemctl is-active identikey-api-proxy' "$resumef"
python3 "$check" pin "$resumef"
rm -f "$resumef"
python3 "$check" state "/var/lib/mjolnir/state/$proxy_id.json" "$proxy_id" "$name" "$run_id"
plantf=$(mktemp)
guest_file "$proxy_id" 'ip route add default dev eth0; ip route; echo ---; /usr/local/lib/mjolnir-spike/probe.sh' "$plantf"
python3 "$check" confinement "$plantf"
rm -f "$plantf"
say "reboot resumed the pin and the unit boundary"

ordinary_body=$(mktemp)
chmod 600 "$ordinary_body"
ordinary_id=$(spawn "$(python3 "$check" payload ordinary "$run_id")" "$ordinary_body") \
  || fail "ordinary spawn"
python3 "$check" spawn "$ordinary_body"
rm -f "$ordinary_body"
ordf=$(mktemp)
guest_file "$ordinary_id" 'ip route; echo ---; cat /etc/resolv.conf' "$ordf"
python3 "$check" ordinary "$ordf"
rm -f "$ordf"
say "ordinary image with enable_iroh false keeps the public route"
echo ACCEPT_OK
