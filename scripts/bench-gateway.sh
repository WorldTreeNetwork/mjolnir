#!/usr/bin/env bash
set -euo pipefail

# Benchmark gateway latency (cold vs warm requests).
#
# Usage:
#   ./scripts/bench-gateway.sh <z32-subdomain> [count]
#   ./scripts/bench-gateway.sh <z32-subdomain> 20
#   ./scripts/bench-gateway.sh <z32-subdomain> 10 --port 3000

SUBDOMAIN="${1:?Usage: $0 <z32-subdomain> [count] [--port N]}"
COUNT="${2:-10}"
DOMAIN="vm.worldtree.network"
PORT=""

# Parse optional --port flag
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="-$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

URL="https://${SUBDOMAIN}${PORT}.${DOMAIN}/"

echo "Target: ${URL}"
echo ""

echo "=== Cold request ==="
curl -w "TTFB: %{time_starttransfer}s  Total: %{time_total}s\n" -s -o /dev/null "${URL}"

echo ""
echo "=== Warm requests (${COUNT}x) ==="
printf "%5s  %10s  %10s\n" "#" "TTFB" "Total"
printf "%5s  %10s  %10s\n" "---" "--------" "--------"

sum_ttfb=0
for i in $(seq 1 "$COUNT"); do
    line=$(curl -w "%{time_starttransfer} %{time_total}" -s -o /dev/null "${URL}")
    ttfb=$(echo "$line" | awk '{print $1}')
    total=$(echo "$line" | awk '{print $2}')
    printf "%5d  %8ss  %8ss\n" "$i" "$ttfb" "$total"
    sum_ttfb=$(echo "$sum_ttfb + $ttfb" | bc)
done

avg=$(echo "scale=3; $sum_ttfb / $COUNT" | bc)
echo ""
echo "Average TTFB: ${avg}s"
