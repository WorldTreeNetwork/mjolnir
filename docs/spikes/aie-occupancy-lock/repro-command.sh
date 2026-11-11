#!/usr/bin/env bash
# Spike aie-occupancy-lock: sidecar and ironlab share occupancy.lock
# through second-run refusal, timeout/cancel quiescence, and restart.
# Framework5070 local only. Does not spawn VMs, does not load guest xclbins,
# does not install units. Advisory flock only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SIDECAR="${SIDECAR:-$ROOT/sidecar.py}"
IRONLAB="${IRONLAB:-/home/dorje/work/AI/parakeet-aie/target/debug/ironlab}"
XCLBIN="${XCLBIN:-/home/dorje/work/AI/parakeet-aie/third_party/xdna-driver/src/shim_ve2/Runner/latency/validate.xclbin}"
MARKER="${MARKER:-/tmp/aie-occupancy-lock-worker.pid}"
READY="${READY:-/tmp/aie-occupancy-lock-ready}"
LOG="${LOG:-$ROOT/evidence.log}"
PASS=0
FAIL=0

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"
}

run() {
  log "+ $*"
  "$@"
}

cleanup() {
  pkill -f 'sidecar.py hold' 2>/dev/null || true
  pkill -f 'sidecar.py timeout' 2>/dev/null || true
  pkill -f 'ironlab load' 2>/dev/null || true
  rm -f "$MARKER" "$READY"
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/ironlab/timeout-expired.flag" 2>/dev/null || true
}
trap cleanup EXIT

wait_file() {
  local path="$1"
  local n="${2:-50}"
  local i
  for i in $(seq 1 "$n"); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 0.1
  done
  log "timeout waiting for $path"
  return 1
}

: >"$LOG"
log "spike aie-occupancy-lock start host=$(uname -n) kernel=$(uname -r)"
log "user=$(id -un) euid=$(id -u) XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
log "ironlab=$IRONLAB"
log "sidecar=$SIDECAR"

python3 "$SIDECAR" paths | tee -a "$LOG"
LOCK_DIR="$(python3 "$SIDECAR" paths | awk -F= '/^occupancy_dir=/{print $2}')"
LOCK_FILE="$LOCK_DIR/occupancy.lock"
log "quoted_lock_path=$LOCK_FILE"

"$IRONLAB" --version | tee -a "$LOG"
"$IRONLAB" doctor --plain | tee -a "$LOG"
"$IRONLAB" status --plain | tee -a "$LOG"

assert_occupied() {
  local label="$1"
  local out rc
  set +e
  out=$(python3 "$SIDECAR" try --bundle "probe-$label" 2>&1)
  rc=$?
  set -e
  log "probe[$label] rc=$rc out=$out"
  if [[ $rc -ne 0 && "$out" == *"occupied"* ]]; then
    log "PASS $label: second process refused"
    PASS=$((PASS + 1))
    return 0
  fi
  log "FAIL $label: expected occupied, got rc=$rc $out"
  FAIL=$((FAIL + 1))
  return 1
}

assert_claimed() {
  local label="$1"
  local out rc
  set +e
  out=$(python3 "$SIDECAR" try --bundle "probe-$label" 2>&1)
  rc=$?
  set -e
  log "probe[$label] rc=$rc out=$out"
  if [[ $rc -eq 0 && "$out" == *"claimed"* ]]; then
    log "PASS $label: try-lock admitted after release"
    PASS=$((PASS + 1))
    return 0
  fi
  log "FAIL $label: expected claim, got rc=$rc $out"
  FAIL=$((FAIL + 1))
  return 1
}

# ---------------------------------------------------------------------------
# 1. Share identity: ironlab holds → sidecar EWOULDBLOCK; reverse.
# ---------------------------------------------------------------------------
log "=== TEST 1a ironlab load holds, sidecar try-lock refused ==="
if [[ ! -x "$IRONLAB" ]]; then
  log "FAIL ironlab binary missing"
  FAIL=$((FAIL + 1))
else
  "$IRONLAB" load "$XCLBIN" >>"$LOG" 2>&1 &
  iron_pid=$!
  log "ironlab load pid=$iron_pid xclbin=$XCLBIN"
  for i in $(seq 1 40); do
    if "$IRONLAB" status --plain 2>/dev/null | grep -q "occupancy: pid"; then
      break
    fi
    sleep 0.15
  done
  "$IRONLAB" status --plain | tee -a "$LOG"
  log "occupancy.json=$(cat "$LOCK_DIR/occupancy.json" 2>/dev/null || echo missing)"
  assert_occupied "ironlab-holds-sidecar-try" || true
  # reverse-direction python second process also
  kill -INT "$iron_pid" 2>/dev/null || true
  wait "$iron_pid" 2>/dev/null || true
  sleep 0.3
fi

log "=== TEST 1b sidecar holds, ironlab load refused ==="
rm -f "$READY" "$MARKER"
python3 "$SIDECAR" hold --bundle sidecar-vs-ironlab --worker-sec 20 --marker "$MARKER" --inherit --ready "$READY" >>"$LOG" 2>&1 &
sc_pid=$!
wait_file "$READY" 50 || true
log "sidecar hold pid=$sc_pid worker=$(cat "$MARKER" 2>/dev/null || echo none) ready=$(cat "$READY" 2>/dev/null || echo none)"
log "occupancy.json=$(cat "$LOCK_DIR/occupancy.json" 2>/dev/null || echo missing)"
"$IRONLAB" status --plain | tee -a "$LOG"
set +e
iron_out=$("$IRONLAB" load "$XCLBIN" 2>&1)
iron_rc=$?
set -e
log "ironlab load while sidecar holds rc=$iron_rc out=$iron_out"
if [[ $iron_rc -ne 0 ]] && [[ "$iron_out" == *"occupied"* || "$iron_out" == *"refused"* ]]; then
  log "PASS 1b: ironlab refused while sidecar holds same lock=$LOCK_FILE"
  PASS=$((PASS + 1))
else
  log "FAIL 1b: ironlab was not refused: rc=$iron_rc $iron_out"
  FAIL=$((FAIL + 1))
fi
assert_occupied "sidecar-holds-second-python" || true
kill -TERM "$sc_pid" 2>/dev/null || true
wait "$sc_pid" 2>/dev/null || true
sleep 0.4
"$IRONLAB" status --plain | tee -a "$LOG"
assert_claimed "after-1b-release" || true

# ---------------------------------------------------------------------------
# 2. Timeout/cancel wait for quiescence before flock release.
# ---------------------------------------------------------------------------
log "=== TEST 2a timeout: request expires, worker still alive, flock held ==="
rm -f "$READY" "$MARKER"
EXPIRED="${XDG_RUNTIME_DIR:-/tmp}/ironlab/timeout-expired.flag"
rm -f "$EXPIRED"
python3 "$SIDECAR" timeout --bundle sidecar-timeout --worker-sec 5 --request-timeout 0.8 --marker "$MARKER" --inherit --ready "$READY" >>"$LOG" 2>&1 &
to_pid=$!
wait_file "$READY" 50 || true
wait_file "$EXPIRED" 40 || true
log "timeout sidecar pid=$to_pid worker=$(cat "$MARKER" 2>/dev/null || echo none) expired=$(cat "$EXPIRED" 2>/dev/null || echo none)"
if [[ -f "$MARKER" ]] && pid_alive=$(cat "$MARKER") && [[ -d /proc/$pid_alive ]]; then
  log "worker still alive pid=$pid_alive during request timeout (required)"
  assert_occupied "timeout-worker-still-alive" || true
else
  log "FAIL 2a: worker was not alive at request timeout"
  FAIL=$((FAIL + 1))
fi
wait "$to_pid" 2>/dev/null || true
sleep 0.2
assert_claimed "after-timeout-quiescence" || true

log "=== TEST 2b cancel: SIGTERM waits for worker, second try refused until then ==="
rm -f "$READY" "$MARKER"
python3 "$SIDECAR" hold --bundle sidecar-cancel --worker-sec 4 --marker "$MARKER" --inherit --ready "$READY" >>"$LOG" 2>&1 &
c_pid=$!
wait_file "$READY" 50 || true
wpid=$(cat "$MARKER" 2>/dev/null || echo 0)
log "cancel sidecar pid=$c_pid worker=$wpid; sending SIGTERM (request cancel)"
kill -TERM "$c_pid" 2>/dev/null || true
# Immediately after cancel, worker may still be dying; flock must stay until wait.
sleep 0.05
if [[ -d /proc/$c_pid ]]; then
  assert_occupied "cancel-before-quiescence" || true
else
  # process already gone — check whether we can claim only if worker gone
  if [[ -d /proc/$wpid ]]; then
    log "FAIL 2b: sidecar exited while worker $wpid still alive"
    FAIL=$((FAIL + 1))
  else
    log "PASS 2b: sidecar and worker both gone after cancel (fast worker)"
    PASS=$((PASS + 1))
  fi
fi
wait "$c_pid" 2>/dev/null || true
sleep 0.2
assert_claimed "after-cancel-quiescence" || true

# ---------------------------------------------------------------------------
# 3. Restart: SIGKILL sidecar with live inherited worker; new try-lock refuses.
# ---------------------------------------------------------------------------
log "=== TEST 3a SIGKILL sidecar, worker inherits flock, second claim refused ==="
rm -f "$READY" "$MARKER"
python3 "$SIDECAR" hold --bundle sidecar-restart --worker-sec 8 --marker "$MARKER" --inherit --self-kill-after 0.6 --ready "$READY" >>"$LOG" 2>&1 &
r_pid=$!
wait_file "$READY" 50 || true
wpid=$(cat "$MARKER" 2>/dev/null || echo 0)
log "restart sidecar pid=$r_pid worker=$wpid (waiting for self-SIGKILL)"
for i in $(seq 1 40); do
  if [[ ! -d /proc/$r_pid ]]; then
    break
  fi
  sleep 0.1
done
log "sidecar dead? $([[ -d /proc/$r_pid ]] && echo no || echo yes) worker_alive=$([[ -d /proc/$wpid ]] && echo yes || echo no)"
log "occupancy.json after SIGKILL=$(cat "$LOCK_DIR/occupancy.json" 2>/dev/null || echo missing)"
if [[ ! -d /proc/$wpid ]]; then
  log "FAIL 3a: worker died before probe (too fast)"
  FAIL=$((FAIL + 1))
else
  assert_occupied "restart-orphan-worker-holds-flock" || true
fi
# wait for worker to finish, then claim should succeed
if [[ -d /proc/$wpid ]]; then
  log "waiting for inherited worker $wpid to exit"
  while [[ -d /proc/$wpid ]]; do sleep 0.2; done
fi
sleep 0.2
assert_claimed "after-orphan-worker-reaped" || true

log "=== TEST 3b control: SIGKILL without inherit → occupancy.rs steal admits while worker lives ==="
rm -f "$READY" "$MARKER"
python3 "$SIDECAR" hold --bundle sidecar-naive --worker-sec 8 --marker "$MARKER" --no-inherit --self-kill-after 0.6 --ready "$READY" >>"$LOG" 2>&1 &
n_pid=$!
wait_file "$READY" 50 || true
wpid=$(cat "$MARKER" 2>/dev/null || echo 0)
for i in $(seq 1 40); do
  if [[ ! -d /proc/$n_pid ]]; then
    break
  fi
  sleep 0.1
done
log "naive sidecar dead worker_alive=$([[ -d /proc/$wpid ]] && echo yes || echo no) json=$(cat "$LOCK_DIR/occupancy.json" 2>/dev/null || echo missing)"
set +e
naive_out=$(python3 "$SIDECAR" try --bundle "probe-naive-steal" 2>&1)
naive_rc=$?
set -e
log "naive probe rc=$naive_rc out=$naive_out"
if [[ -d /proc/$wpid ]]; then
  if [[ $naive_rc -eq 0 ]]; then
    log "NOTE 3b: without inherit, try-lock SUCCEEDED while orphan worker $wpid lived (occupancy.rs steal). This is why cooperating sidecar must inherit the flock fd or refuse on live worker pid."
    PASS=$((PASS + 1))
  else
    log "NOTE 3b: without inherit, try-lock still refused (unexpected but fail-closed). out=$naive_out"
    PASS=$((PASS + 1))
  fi
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
else
  log "FAIL 3b: naive worker not alive for steal demonstration"
  FAIL=$((FAIL + 1))
fi
# cleanup leftover flock
python3 "$SIDECAR" try --bundle cleanup >/dev/null 2>&1 || true
"$IRONLAB" status --plain | tee -a "$LOG"

log "=== SUMMARY pass=$PASS fail=$FAIL lock=$LOCK_FILE ==="
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
