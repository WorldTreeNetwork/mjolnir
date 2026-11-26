#!/usr/bin/env bash
# Claim 2: a native MoQ publisher (ffmpeg-encoded fixture: green|purple halves, 440 Hz) is played over WHEP
# through the edge by Chromium and Firefox. The page samples decoded pixels and the audio spectrum.
#   ./claim2-whep.sh <h264|vp8|vp9|av1> <chromium|firefox ...>
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
VC=$1; shift
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
start_relay; start_edge; start_pages
for n in carol erin; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES
echo "# claim2 WHEP out: source codec=$VC $(date -u +%FT%TZ)"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 "$VC" $((14 * $#)) ) & PUB=$!
pause 2.5
rc=0
for b in "$@"; do
  echo "## $b"
  node drive.mjs play "$b" carol/cam - 8 0x28B43C 0x7828AA 440 erin || rc=1
done
kill $PUB 2>/dev/null
echo "## edge log"; grep -E "accepted|ended|refused|WARN|ERROR" "$P/edge.log" | grep -v "TLS server cert" | cut -c1-260
exit $rc
