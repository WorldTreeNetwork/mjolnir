#!/bin/sh
# One ramp. Stops when delivery < 0.99 or p95 > 300.
# Usage: ramp-one.sh BIN TRANSPORT KBPS LABEL
# RELAY_CORES=0-3 taskset -c 4-11 ramp-one.sh ...   # loopback split of cores
# Extra args after label are passed to relay-scale (for example --connect).
set -eu
bin=$1
transport=$2
kbps=$3
label=$4
shift 4
out=${OUT:-results-ramp.txt}
echo "RAMP label=$label transport=$transport video_kbps=$kbps load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)" | tee -a "$out"
run() {
  rooms=$1
  parts=$2
  echo "STEP rooms=$rooms participants=$parts load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo na)" | tee -a "$out"
  line=$(timeout 120 "$bin" run --transport "$transport" --rooms "$rooms" --participants "$parts" --seconds 6 --video-kbps "$kbps" "$@" | tee -a "$out" | grep '^RESULT ' | tail -1 || true)
  if [ -z "$line" ]; then
    echo "STOP no result" | tee -a "$out"
    return 0
  fi
  delivery=$(printf '%s\n' "$line" | sed -n 's/.* delivery=\([0-9.]*\).*/\1/p')
  p95=$(printf '%s\n' "$line" | sed -n 's/.* p95_ms=\([0-9]*\).*/\1/p')
  awk -v d="$delivery" -v p="$p95" 'BEGIN { exit !((d+0) < 0.99 || (p+0) > 300) }'
}
for rooms in 1 2 4 8; do
  if run "$rooms" 4 "$@"; then
    echo "KNEE rooms=$rooms participants=4 label=$label" | tee -a "$out"
    break
  fi
done
for parts in 2 4 8 16 32 50; do
  if run 2 "$parts" "$@"; then
    echo "KNEE rooms=2 participants=$parts label=$label" | tee -a "$out"
    break
  fi
done
