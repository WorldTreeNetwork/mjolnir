#!/bin/bash
# Follow-up: IPv4-mapped peers with IPv6 relay on; whether strict_expiry
# stops an existing allocation; uid OUTPUT drop with the client outside the
# dropped ranges. Dummy secret. Not production.
set -u
SECRET='dummy-turn-secret-not-a-real-key'
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=/tmp/mjolnir-turn-spike
OUT=${1:-/tmp/turn-spike-out2}
mkdir -p "$WORK/run" "$OUT"
TUID=$(id -u mjolnir-turn-spike)

cleanup() {
  sudo docker rm -f mjolnir-turn-spike >/dev/null 2>&1 || true
  sudo iptables -D OUTPUT -m comment --comment mjolnir-turn -j MJOLNIR_TURN_SPIKE 2>/dev/null || true
  sudo iptables -F MJOLNIR_TURN_SPIKE 2>/dev/null || true
  sudo iptables -X MJOLNIR_TURN_SPIKE 2>/dev/null || true
  sudo ip netns del turnspike 2>/dev/null || true
  sudo ip link del veth-ts 2>/dev/null || true
  sudo ip addr del 192.0.2.10/32 dev dummy-mjolnir 2>/dev/null || true
  sudo ip addr del 2001:db8::10/128 dev dummy-mjolnir 2>/dev/null || true
}
trap cleanup EXIT
cleanup || true

sudo ip addr add 192.0.2.10/32 dev dummy-mjolnir
sudo ip addr add 2001:db8::10/128 dev dummy-mjolnir

cat >"$WORK/eturnal.yml" <<EOF
eturnal:
  secret: "$SECRET"
  realm: "turn.spike.invalid"
  relay_ipv4_addr: "192.0.2.10"
  relay_ipv6_addr: "2001:db8::10"
  relay_min_port: 61000
  relay_max_port: 61020
  blacklist_peers:
    - recommended
    - "10.200.0.0/16"
    - "10.0.0.0/8"
  strict_expiry: true
  log_dir: stdout
  log_level: info
  run_dir: /tmp/run
  listen:
    - ip: "127.0.0.1"
      port: 3478
      transport: udp
  modules: {}
EOF
chmod 644 "$WORK/eturnal.yml"
sudo chown "$TUID:$TUID" "$WORK/run"
sudo docker rm -f mjolnir-turn-spike >/dev/null 2>&1 || true
sudo docker run -d --name mjolnir-turn-spike --network host --user "$TUID:$TUID" \
  -v "$WORK/eturnal.yml:/opt/eturnal/etc/eturnal.yml:ro" \
  -v "$WORK/run:/tmp/run" \
  ghcr.io/processone/eturnal:1.12.3 >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ss -uln | grep -q ':3478' && break
  sleep 0.3
done
ss -uln | grep 3478 | tee "$OUT/s1b-listen.txt"
sudo docker logs mjolnir-turn-spike | tee "$OUT/s1b-boot.txt"

USERN="$(($(date +%s)+120)):c1.DummyOwner111111111111.room1.part1"
python3 "$HERE/turn_client.py" --secret "$SECRET" --username "$USERN" --do blacklist \
  --peer ::ffff:10.200.0.1 --peer ::1 --peer fe80::1 --peer 2001:db8::1 --peer ::ffff:127.0.0.1 \
  | tee "$OUT/s1b-mapped.txt" || true

# Existing allocation after the username timestamp: permission first, then wait.
EXP=$(($(date +%s)+6))
U2="${EXP}:c1.DummyOwner111111111111.room1.part1"
python3 "$HERE/turn_client.py" --secret "$SECRET" --username "$U2" --do send --peer 1.1.1.1 \
  | tee "$OUT/s1b-before-expiry.txt"
echo "waiting for expiry" | tee -a "$OUT/s1b-before-expiry.txt"
# The wait is the credential lifetime under test, not a poll.
python3 - <<PY
import time
time.sleep(8)
PY
sudo timeout 4 tcpdump -i eno1 -n -c 2 'udp and host 1.1.1.1 and port 9' >"$OUT/s1b-after-expiry-tcpdump.txt" 2>&1 &
TD=$!
sleep 0.4
python3 "$HERE/turn_client.py" --secret "$SECRET" --username "$U2" --do send --peer 1.1.1.1 \
  | tee "$OUT/s1b-after-expiry-send.txt" || true
sudo docker exec -u "$TUID" mjolnir-turn-spike eturnalctl sessions | tee "$OUT/s1b-sessions-after.txt" || true
wait "$TD" || true
sudo docker logs mjolnir-turn-spike >"$OUT/s1b-eturnal.log" 2>&1 || true
sudo docker rm -f mjolnir-turn-spike >/dev/null 2>&1 || true

# S2 proper. Client lives in a netns at 203.0.113.50, which is outside every
# drop destination. The server listens on 203.0.113.1. Relayed packets still
# come from uid $TUID.
sudo ip netns add turnspike
sudo ip link add veth-ts type veth peer name veth-ts-ns
sudo ip link set veth-ts-ns netns turnspike
sudo ip addr add 203.0.113.1/24 dev veth-ts
sudo ip link set veth-ts up
sudo ip netns exec turnspike ip addr add 203.0.113.50/24 dev veth-ts-ns
sudo ip netns exec turnspike ip link set veth-ts-ns up
sudo ip netns exec turnspike ip link set lo up
sudo ip netns exec turnspike ip route add default via 203.0.113.1

cat >"$WORK/eturnal.yml" <<EOF
eturnal:
  secret: "$SECRET"
  realm: "turn.spike.invalid"
  relay_ipv4_addr: "192.0.2.10"
  relay_ipv6_addr: none
  relay_min_port: 61000
  relay_max_port: 61020
  blacklist_peers:
    - "198.51.100.9/32"
  strict_expiry: true
  log_dir: stdout
  log_level: info
  run_dir: /tmp/run
  listen:
    - ip: "203.0.113.1"
      port: 3478
      transport: udp
  modules: {}
EOF
sudo docker run -d --name mjolnir-turn-spike --network host --user "$TUID:$TUID" \
  -v "$WORK/eturnal.yml:/opt/eturnal/etc/eturnal.yml:ro" \
  -v "$WORK/run:/tmp/run" \
  ghcr.io/processone/eturnal:1.12.3 >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ss -uln | grep -q '203.0.113.1:3478' && break
  sleep 0.3
done

sudo iptables -N MJOLNIR_TURN_SPIKE
sudo iptables -I OUTPUT 1 -m comment --comment mjolnir-turn -j MJOLNIR_TURN_SPIKE
for dest in 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 224.0.0.0/4; do
  sudo iptables -A MJOLNIR_TURN_SPIKE -m owner --uid-owner "$TUID" -d "$dest" -m comment --comment mjolnir-turn -j DROP
done
sudo iptables -A MJOLNIR_TURN_SPIKE -m owner --uid-owner "$TUID" -d 1.1.1.1/32 -m comment --comment mjolnir-turn -j RETURN

sudo ip route replace 169.254.1.1/32 dev dummy-mjolnir
sudo ip route replace 10.1.2.3/32 dev dummy-mjolnir

sudo timeout 6 tcpdump -i dummy-mjolnir -n -c 10 'udp and port 9' >"$OUT/s2-tcpdump-dummy.txt" 2>&1 &
sudo timeout 6 tcpdump -i lo -n -c 5 'udp and port 9' >"$OUT/s2-tcpdump-lo.txt" 2>&1 &
sudo timeout 6 tcpdump -i eno1 -n -c 3 'udp and host 1.1.1.1 and port 9' >"$OUT/s2-tcpdump-eno1.txt" 2>&1 &
sleep 0.4
sudo ip netns exec turnspike python3 "$HERE/turn_client.py" --host 203.0.113.1 --secret "$SECRET" \
  --username "$(($(date +%s)+300)):g1.DummyOwner111111111111.label" \
  --do send \
  --peer 10.200.0.1 --peer 127.0.0.1 --peer 169.254.1.1 --peer 10.1.2.3 --peer 192.168.0.164 --peer 1.1.1.1 \
  | tee "$OUT/s2-send.txt" || true
sleep 1
sudo iptables -L MJOLNIR_TURN_SPIKE -v -n -x | tee "$OUT/s2-counters.txt"
sudo ip route del 169.254.1.1/32 dev dummy-mjolnir 2>/dev/null || true
sudo ip route del 10.1.2.3/32 dev dummy-mjolnir 2>/dev/null || true
sudo docker logs mjolnir-turn-spike >"$OUT/s2-eturnal.log" 2>&1 || true
echo followup-done
