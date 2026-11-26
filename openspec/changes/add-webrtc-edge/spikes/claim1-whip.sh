#!/usr/bin/env bash
# Claim 1: Chromium (fake camera = fixture colours, fake mic = 1 kHz) publishes over WHIP through the edge.
# MoQ readers through the relay, each with its own room token:
#   dave  plain subscriber, subscribed before the publish        -> IVF/Annex-B + Ogg Opus, decoded by ffmpeg
#   erin  plain subscriber, joins ~7 s after the publish          -> same
#   frank moq-mux MKV exporter (player-shaped: latency window), joins late -> MKV
#   ./claim1-whip.sh <VP8|H264|VP9|AV1> [cap-mbps, 0 = uncapped]
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
VC=$1; CAP=${2:-2.5}
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
rm -f "$P"/c1-*; start_relay; EDGE_INGEST_MBPS=$CAP start_edge; start_pages
for n in alice dave erin frank; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES
echo "# claim1 WHIP in: codec=$VC ingest-cap=${CAP}Mbps $(date -u +%FT%TZ)"
timeout 40 "$BIN/harness" raw "$(relay_url "$(cat "$P/dave.tok")")" alice/cam 14 "$P/c1-dave.x" > "$P/c1-dave.out" 2>&1 & E1=$!
node drive.mjs pub alice alice/cam "$VC" 15 > "$P/pub-alice.out" 2>&1 & D=$!
wait_grep "$P/pub-alice.out" '"step":"publish"'
pause 7
timeout 30 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" alice/cam 6 "$P/c1-erin.x" > "$P/c1-erin.out" 2>&1 & E2=$!
timeout 30 "$BIN/harness" export "$(relay_url "$(cat "$P/frank.tok")")" alice/cam 6 "$P/c1-frank.mkv" > "$P/c1-frank.out" 2>&1 & E3=$!
wait $E1 $E2 $E3 $D
echo "## browser (publisher)"; cat "$P/pub-alice.out"
for r in dave erin; do
  echo "## MoQ plain subscriber $r"; grep '^raw' "$P/c1-$r.out"
  python3 "$here/analyze.py" 0xC83278 0x1EA0A0 1000 $(ls "$P"/c1-$r.ivf "$P"/c1-$r.h264 2>/dev/null) "$P/c1-$r.opus"; echo "exit=$?"
done
echo "## moq-mux MKV exporter frank (late)"; grep -E '^export' "$P/c1-frank.out"
python3 "$here/analyze.py" 0xC83278 0x1EA0A0 1000 "$P"/c1-frank.*.mkv; echo "exit=$?"
echo "## edge log"; grep -E "accepted|ended|refused|WARN|ERROR" "$P/edge.log" | grep -v "TLS server cert" | cut -c1-260
