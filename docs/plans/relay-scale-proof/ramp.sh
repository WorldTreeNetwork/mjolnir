#!/bin/sh
# Ramp one transport until delivery < 99% or p95 latency > 300 ms.
# Usage: ./ramp.sh wt|iroh
set -eu
transport=${1:?wt or iroh}
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
bin=$here/harness/target/release/relay-scale
mkdir -p "$here/results"
out=$here/results/ramp-$transport.txt
: > "$out"
run() {
  rooms=$1
  parts=$2
  echo "STEP rooms=$rooms participants=$parts" | tee -a "$out"
  # timeout is the whole step, including relay bind.
  if ! line=$(timeout 90 "$bin" run --transport "$transport" --rooms "$rooms" --participants "$parts" --seconds 8 --video-kbps 1000 | tee -a "$out" | grep '^RESULT ' | tail -1); then
    echo "STOP step failed" | tee -a "$out"
    return 1
  fi
  delivery=$(printf '%s\n' "$line" | sed -n 's/.* delivery=\([0-9.]*\).*/\1/p')
  p95=$(printf '%s\n' "$line" | sed -n 's/.* p95_ms=\([0-9]*\).*/\1/p')
  awk -v d="$delivery" -v p="$p95" 'BEGIN { exit !((d+0) < 0.99 || (p+0) > 300) }'
}
echo "transport=$transport video_kbps=1000 seconds=8" >> "$out"
# Fixed P=4, raise N.
for rooms in 1 2 4 8; do
  if run "$rooms" 4; then
    echo "KNEE rooms=$rooms participants=4" | tee -a "$out"
    break
  fi
done
# Fixed N=2, raise P. 50 is the top of the brief.
for parts in 2 4 8 16 32 50; do
  if run 2 "$parts"; then
    echo "KNEE rooms=2 participants=$parts" | tee -a "$out"
    break
  fi
done
echo "ramp done $out"
