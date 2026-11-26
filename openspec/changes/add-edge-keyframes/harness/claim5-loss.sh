#!/usr/bin/env bash
# Claim 5: packet loss and simulcast.
#   loss: a UDP proxy (lossy.py) sits between Chromium and the edge's media port; the edge advertises it.
#     egress: native VP8 publisher -> WHEP play with LOSS dropped toward the browser
#     ingest: WHIP publish with LOSS dropped toward the edge -> plain MoQ reader
#   simulcast: Chromium publishes three rids on one video line; what the catalog and a reader get.
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
LOSS=${LOSS:-0.05}
cd "$HARNESS" && cp "$here/drive.mjs" .
trap 'stop_all; [ -n "${PX:-}" ] && kill $PX 2>/dev/null' EXIT
rm -f "$P"/c5-*; start_relay
EDGE_ADVERTISE=$LAN:40001 "$BIN/edge" 127.0.0.1:8088 "$LAN:40000" "https://$(cat "$P/relay.txt")/" "$P/verify.json" > "$P/edge.log" 2>&1 &
echo $! > "$P/edge.pid"; wait_grep "$P/edge.log" "edge up"; start_pages
for n in alice carol erin; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES STRIP=1
echo "# claim5 loss=$LOSS $(date -u +%FT%TZ)"
echo "## egress: WHEP play of a native VP8 source, ${LOSS} loss toward the browser"
python3 "$here/lossy.py" "$LAN:40001" "$LAN:40000" "$LOSS" 0 > "$P/c5-proxy1.out" 2>&1 & PX=$!
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 25 ) & PUB=$!
pause 2.5
node drive.mjs play chromium carol/cam - 15 0x28B43C 0x7828AA 440 erin; echo "exit=$?"
kill $PX; wait $PX 2>/dev/null; echo "proxy: $(cat "$P/c5-proxy1.out")"; kill $PUB 2>/dev/null
echo "## ingest: WHIP publish (VP8), ${LOSS} loss toward the edge, read by a plain MoQ subscriber"
python3 "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 "$LOSS" > "$P/c5-proxy2.out" 2>&1 & PX=$!
node drive.mjs pub alice alice/cam VP8 15 > "$P/c5-pub.out" 2>&1 & D=$!
wait_grep "$P/c5-pub.out" '"step":"publish"'; pause 3
timeout 30 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" alice/cam 10 "$P/c5-ingest.x" 2>&1 | grep "^raw"
python3 "$here/analyze.py" 0xC83278 0x1EA0A0 1000 "$P/c5-ingest.ivf" "$P/c5-ingest.opus"
wait $D; cat "$P/c5-pub.out" | tail -1
kill $PX; wait $PX 2>/dev/null; echo "proxy: $(cat "$P/c5-proxy2.out")"
echo "## simulcast: three rids on one video line (no loss)"
python3 "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 > /dev/null 2>&1 & PX=$!
node drive.mjs simulcast alice alice/sim 10 > "$P/c5-sim.out" 2>&1 & D=$!
wait_grep "$P/c5-sim.out" 'publish-simulcast'; head -1 "$P/c5-sim.out"; pause 4
timeout 20 "$BIN/harness" catalog "$(relay_url "$(cat "$P/erin.tok")")" alice/sim 2>&1 | grep -oE '"[0-9]+\.[a-z0-9]+(/[0-9]+)?": (Video|Audio)Config|coded_width: Some\([0-9]+\)' | tr '\n' ' '; echo
timeout 20 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" alice/sim 5 "$P/c5-sim.x" 2>&1 | grep "^raw"
python3 "$here/analyze.py" 0xC83278 0x1EA0A0 1000 "$P/c5-sim.ivf" "$P/c5-sim.opus"
ffmpeg -v info -i "$P/c5-sim.ivf" -vf showinfo -f null - 2>&1 | grep -oE ' s:[0-9]+x[0-9]+' | sort | uniq -c | sed 's/^/decoded frames at /'
wait $D; tail -1 "$P/c5-sim.out" | cut -c1-900
echo "## edge log (keyframe requests are debug-level; warnings shown)"; grep -E "WARN|ERROR|ended" "$P/edge.log" | grep -v "TLS server cert" | grep -v "group evicted" | cut -c1-220 | tail -15
echo "group-evicted warnings: $(grep -c 'group evicted' "$P/edge.log")"
