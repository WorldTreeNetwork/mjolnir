#!/usr/bin/env bash
# Claim 3: one room, two WebRTC participants and one MoQ participant.
#   alice, bob: Chromium, each a WHIP publish of its own fixture, then GET /roster and one WHEP play per other broadcast.
#   carol: native MoQ, publishes her fixture (VP8) and reads alice and bob as a plain subscriber.
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
rm -f "$P"/c3-*; start_relay; EDGE_INGEST_MBPS=2.5 start_edge; start_pages
for n in alice bob carol; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES
echo "# claim3 room $(date -u +%FT%TZ)"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 45 ) & PUB=$!
pause 2
HOLD=6 node drive.mjs room > "$P/c3-room.out" 2>&1 & D=$!
wait_grep "$P/c3-room.out" '"step":"roster","who":"alice"'
R=()
for w in alice bob; do timeout 30 "$BIN/harness" raw "$(relay_url "$(cat "$P/carol.tok")")" $w/cam 8 "$P/c3-carol-reads-$w.x" > "$P/c3-carol-$w.out" 2>&1 & R+=($!); done
wait $D; rc=$?
wait "${R[@]}"
echo "## browsers (rc=$rc)"; cat "$P/c3-room.out"
echo "## carol (MoQ) reads alice"; grep '^raw' "$P/c3-carol-alice.out"
python3 "$here/analyze.py" 0xC83278 0x1EA0A0 1000 $(ls "$P"/c3-carol-reads-alice.{ivf,h264} 2>/dev/null) "$P/c3-carol-reads-alice.opus"; echo "exit=$?"
echo "## carol (MoQ) reads bob"; grep '^raw' "$P/c3-carol-bob.out"
python3 "$here/analyze.py" 0xE68C14 0x283CC8 600 $(ls "$P"/c3-carol-reads-bob.{ivf,h264} 2>/dev/null) "$P/c3-carol-reads-bob.opus"; echo "exit=$?"
kill $PUB 2>/dev/null
echo "## edge sessions"; grep -E "session accepted|session ended|refused" "$P/edge.log" | cut -c1-230
