#!/usr/bin/env bash
# Spike aie-npu-path: host sidecar on dummy-mjolnir, guest curls NPU vector-add.
# Local Framework5070 only. Cleans up the throwaway VM. Does not touch other guests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOCK="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
BIND="${AIE_SPIKE_BIND:-10.200.0.1}"
PORT="${AIE_SPIKE_PORT:-7422}"
SIDECAR="$ROOT/docs/spikes/aie-npu-path/sidecar.py"
LOG="${AIE_SPIKE_LOG:-/tmp/aie-npu-path-sidecar.log}"

op() {
  sudo curl -sS --unix-socket "$SOCK" "$@"
}

python3 "$SIDECAR" >"$LOG" 2>&1 &
sidecarpid=$!
trap 'kill "$sidecarpid" 2>/dev/null || true' EXIT
for i in $(seq 1 20); do
  curl -sf "http://$BIND:$PORT/health" && break
  sleep 0.2
done
curl -sf "http://$BIND:$PORT/health"
echo

body='{"base_image":"ubuntu-24.04","memory_mb":1024,"vcpus":2,"restart_policy":"never","metadata":{"purpose":"aie-npu-path-spike"}}'
id=$(op -H 'Content-Type: application/json' -X POST http://localhost/api/vms -d "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "spawned $id"
cleanup_vm() {
  op -X DELETE "http://localhost/api/vms/$id" || true
  kill "$sidecarpid" 2>/dev/null || true
}
trap cleanup_vm EXIT

# wait for running
for i in $(seq 1 60); do
  state=$(op "http://localhost/api/vms/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')
  echo "state=$state"
  [[ "$state" == "running" ]] && break
  sleep 2
done

guest() {
  op -H 'Content-Type: application/json' -X POST "http://localhost/api/vms/$id/exec" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")"
  echo
}

guest "curl -sS -m 10 http://$BIND:$PORT/health"
guest "curl -sS -m 120 -X POST http://$BIND:$PORT/hello"
