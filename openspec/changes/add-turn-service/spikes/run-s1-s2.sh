#!/bin/bash
# Lab-only spike runner. Dummy secret. Removes its iptables rules and container.
# Run on a Linux host that is not production. Requires docker, sudo, python3, tcpdump.
set -u
SECRET='dummy-turn-secret-not-a-real-key'
SECRET2='dummy-turn-secret-old-overlap'
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=/tmp/mjolnir-turn-spike
OUT=${1:-/tmp/mjolnir-turn-spike-out}
mkdir -p "$WORK" "$OUT"
rm -rf "$WORK"/*
mkdir -p "$WORK/run"

UIDN=$(id -u)
# Dedicated uid so owner-match is not this login. Reused if present.
if ! id mjolnir-turn-spike >/dev/null 2>&1; then
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin mjolnir-turn-spike
fi
TUID=$(id -u mjolnir-turn-spike)
echo "spike-uid=$TUID login-uid=$UIDN" | tee "$OUT/host.txt"
sysctl net.ipv4.ip_local_port_range | tee -a "$OUT/host.txt"
ip -4 addr show dummy-mjolnir | tee -a "$OUT/host.txt"
ip route get 1.1.1.1 | tee -a "$OUT/host.txt"

write_cfg() {
  local blacklist="$1"
  cat >"$WORK/eturnal.yml" <<EOF
eturnal:
  secret:
    - "$SECRET"
    - "$SECRET2"
  realm: "turn.spike.invalid"
  relay_ipv4_addr: "192.0.2.10"
  relay_ipv6_addr: none
  relay_min_port: 61000
  relay_max_port: 61020
  blacklist_peers:
$blacklist
  strict_expiry: true
  log_dir: stdout
  log_level: info
  run_dir: /tmp/run
  listen:
    - ip: "127.0.0.1"
      port: 3478
      transport: udp
    - ip: "127.0.0.1"
      port: 3478
      transport: tcp
  modules:
    mod_log_stun: {}
EOF
}

start_srv() {
  sudo docker rm -f mjolnir-turn-spike >/dev/null 2>&1 || true
  sudo chown "$TUID:$TUID" "$WORK/run"
  chmod 644 "$WORK/eturnal.yml"
  sudo docker run -d --name mjolnir-turn-spike \
    --network host \
    --user "$TUID:$TUID" \
    -v "$WORK/eturnal.yml:/opt/eturnal/etc/eturnal.yml:ro" \
    -v "$WORK/run:/tmp/run" \
    ghcr.io/processone/eturnal:1.12.3 >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ss -uln | grep -q ':3478'; then
      return 0
    fi
    sleep 0.4
  done
  echo "TURN did not bind" | tee "$OUT/bind-fail.txt"
  sudo docker logs mjolnir-turn-spike | tee "$OUT/bind-fail.txt"
  return 1
}

stop_srv() {
  sudo docker logs mjolnir-turn-spike >"$1" 2>&1 || true
  sudo docker rm -f mjolnir-turn-spike >/dev/null 2>&1 || true
}

# --- S1 ---
write_cfg "$(cat <<'EOF'
    - recommended
    - "10.200.0.0/16"
    - "10.0.0.0/8"
    - "192.168.0.164/32"
EOF
)"
# The host's own address is already inside 192.168.0.0/16 (recommended). Listed
# explicitly so the spike config matches the contract list.
start_srv
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)+300)):c1.DummyOwner111111111111.room1.part1" \
  --do allocate | tee "$OUT/s1-allocate.txt"
python3 "$HERE/turn_client.py" --secret "$SECRET2" \
  --username "$(($(date +%s)+300)):g1.DummyOwner111111111111.label" \
  --do allocate | tee "$OUT/s1-second-secret.txt"
EXP=$(($(date +%s)+6))
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "${EXP}:c1.DummyOwner111111111111.room1.part1" \
  --do refresh-wait --wait 8 | tee "$OUT/s1-expiry.txt"
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)-30)):c1.DummyOwner111111111111.room1.part1" \
  --do allocate | tee "$OUT/s1-already-expired.txt"
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)+300)):c1.DummyOwner111111111111.room1.part1" \
  --do blacklist \
  --peer 10.200.0.1 \
  --peer 127.0.0.1 \
  --peer ::ffff:10.200.0.1 \
  --peer 169.254.1.1 \
  --peer 10.1.2.3 \
  --peer 192.168.0.164 \
  --peer 100.64.1.1 \
  --peer 224.0.0.1 \
  --peer ::1 \
  | tee "$OUT/s1-blacklist.txt"
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)+300)):c1.DummyOwner111111111111.room1.part1" \
  --do tcp | tee "$OUT/s1-tcp-transport.txt"
# One allowed public permission plus a short send, then ask eturnalctl for the session.
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)+300)):c1.DummyOwner111111111111.room1.part1" \
  --do send --peer 1.1.1.1 | tee "$OUT/s1-public-ok.txt" &
sleep 1
sudo docker exec -u "$TUID" mjolnir-turn-spike eturnalctl sessions | tee "$OUT/s1-sessions.txt" || true
wait || true
stop_srv "$OUT/s1-eturnal.log"

# --- S2: daemon blacklist replaced by a single unused prefix ---
write_cfg '    - "203.0.113.0/24"'
start_srv
sudo iptables -N MJOLNIR_TURN_SPIKE 2>/dev/null || sudo iptables -F MJOLNIR_TURN_SPIKE
sudo iptables -C OUTPUT -m comment --comment mjolnir-turn -j MJOLNIR_TURN_SPIKE 2>/dev/null \
  || sudo iptables -I OUTPUT 1 -m comment --comment mjolnir-turn -j MJOLNIR_TURN_SPIKE
for dest in 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 224.0.0.0/4 192.168.0.164/32; do
  sudo iptables -A MJOLNIR_TURN_SPIKE -m owner --uid-owner "$TUID" -d "$dest" -m comment --comment mjolnir-turn -j DROP
done
# A pass counter for the public peer, still matched on the uid, so we can see
# that the chain runs and that this destination is not dropped.
sudo iptables -A MJOLNIR_TURN_SPIKE -m owner --uid-owner "$TUID" -d 1.1.1.1/32 -m comment --comment mjolnir-turn -j RETURN

# Temporary routes so a packet that escaped the filter would hit an interface
# we can capture. Removed in the cleanup below.
sudo ip route replace 169.254.1.1/32 dev dummy-mjolnir
sudo ip route replace 10.1.2.3/32 dev dummy-mjolnir

sudo timeout 8 tcpdump -i dummy-mjolnir -n -c 20 'udp and (host 10.200.0.1 or host 10.1.2.3 or host 169.254.1.1)' >"$OUT/s2-tcpdump-dummy.txt" 2>&1 &
TD1=$!
sudo timeout 8 tcpdump -i lo -n -c 20 'udp and host 127.0.0.1 and port 9' >"$OUT/s2-tcpdump-lo.txt" 2>&1 &
TD2=$!
sudo timeout 8 tcpdump -i eno1 -n -c 5 'udp and host 1.1.1.1 and port 9' >"$OUT/s2-tcpdump-eno1.txt" 2>&1 &
TD3=$!
sleep 0.5
python3 "$HERE/turn_client.py" --secret "$SECRET" \
  --username "$(($(date +%s)+300)):g1.DummyOwner111111111111.label" \
  --do send \
  --peer 10.200.0.1 \
  --peer 127.0.0.1 \
  --peer 169.254.1.1 \
  --peer 10.1.2.3 \
  --peer 192.168.0.164 \
  --peer 1.1.1.1 \
  | tee "$OUT/s2-send.txt"
sleep 1
sudo iptables -L MJOLNIR_TURN_SPIKE -v -n -x | tee "$OUT/s2-counters.txt"
wait "$TD1" "$TD2" "$TD3" || true
stop_srv "$OUT/s2-eturnal.log"

sudo iptables -D OUTPUT -m comment --comment mjolnir-turn -j MJOLNIR_TURN_SPIKE 2>/dev/null || true
sudo iptables -F MJOLNIR_TURN_SPIKE 2>/dev/null || true
sudo iptables -X MJOLNIR_TURN_SPIKE 2>/dev/null || true
sudo ip route del 169.254.1.1/32 dev dummy-mjolnir 2>/dev/null || true
sudo ip route del 10.1.2.3/32 dev dummy-mjolnir 2>/dev/null || true
echo cleaned | tee "$OUT/cleaned.txt"
