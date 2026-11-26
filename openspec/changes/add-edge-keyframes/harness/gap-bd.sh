#!/usr/bin/env bash
# Fill only the unpatched before gaps: B ivf decode, and D2 at 1280x720.
# Same binaries, LAN, and testsrc2 fixture as before-720.sh. Does not rerun A/C/F/D1.
set -u
here=$(cd "$(dirname "$0")" && pwd)
export LAN=${LAN:?}
source "$here/lib.sh"
export P=${P:-/tmp/kf-before720}
export HARNESS=${HARNESS:-/tmp/kf-pw}
mkdir -p "$P/frames"
cd "$HARNESS" && cp -f "$here/drive.mjs" .
FONT=${FONT:-/usr/share/fonts/noto/NotoSans-Regular.ttf}
trap 'stop_all; [ -n "${PX:-}" ] && kill "$PX" 2>/dev/null || true; [ -n "${PUB:-}" ] && kill "$PUB" 2>/dev/null || true' EXIT
echo "gap platform=$(uname -srm) lan=$LAN pin=4a6f52248"
start_relay || { echo "relay failed"; cat "$P/relay.log"; exit 1; }
start_edge || { echo "edge failed"; cat "$P/edge.log"; exit 1; }
echo "edge_up=yes"
start_pages || exit 1
for n in carol erin; do mint r1 "$n" 1200 > "$P/$n.tok"; done
pub_moving() {
  local tok=$1 secs=$2
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -filter_complex "[0:v]drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white[v]" \
    -map "[v]" -map 1:a -t "$secs" -c:v libvpx -deadline realtime -cpu-used 8 -b:v 1500k -g 30 \
    -c:a libopus -b:a 64k -ac 1 -f matroska -live 1 -cluster_time_limit 20 -cluster_size_limit 4096 - \
    2>>"$P/ffmpeg.err" | PUBLISH_FORMAT=mkv "$BIN/harness" publish "$(relay_url "$tok")" carol/cam >>"$P/pub.log" 2>&1
}
if [ "${GAP_D2_ONLY:-}" = 1 ] && [ -s "$P/b-decode.ivf" ]; then
  echo "## B decode hold skipped; ivf already written"
else
echo "## B decode hold"
pub_moving "$(cat "$P/carol.tok")" 20 & PUB=$!
pause 4
timeout 15 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 3 "$P/b-decode" > "$P/b-decode.raw" 2>"$P/b-decode.err" || true
ffprobe -hide_banner -show_entries stream=codec_name,width,height,nb_frames,duration -of compact "$P/b-decode.ivf" || echo "B ivf missing"
ffmpeg -y -v error -i "$P/b-decode.ivf" -frames:v 1 "$P/frames/b0.png" || true
file "$P/frames/b0.png" || true
python3 - << 'PY'
import os
p=os.environ["P"]+"/b-decode.raw"
n=0
for line in open(p):
    if line.startswith("raw-frame"):
        print(line.strip()); n+=1
        if n>=3: break
print("b_decode_frames_printed", n)
PY
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=
fi
echo "## D2 1280x720 WHIP, exact capture, 1.5s burst"
stop_edge
EDGE_ADVERTISE=$LAN:40001 "$BIN/edge" 127.0.0.1:8088 "$LAN:40000" "https://$(cat "$P/relay.txt")/" "$P/verify.json" > "$P/edge-d2.log" 2>&1 &
echo $! > "$P/edge.pid"
wait_grep "$P/edge-d2.log" "edge up" || { echo "D2 edge failed"; cat "$P/edge-d2.log"; exit 1; }
export STRIP=1
# Burst after the WHIP session is up. A burst from the first packet only hits ICE.
python3 -u "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 --burst-after 3 --burst 1.5 > "$P/d2.out" 2>&1 & PX=$!
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -vf "drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white" \
  -t 8 -pix_fmt yuv420p "$P/carol.y4m"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 12 -ac 1 "$P/carol.wav"
node drive.mjs pub carol carol/cam VP8 8 carol > "$P/d2-pub.out" 2>&1 & D=$!
pause 2
timeout 14 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 6 "$P/d2" > "$P/d2.raw" 2>"$P/d2.err" || true
wait "$D" || true
echo "D2 proxy $(cat "$P/d2.out" 2>/dev/null || true)"
echo "D2 loss-cause $(rg -c 'loss-cause|cause=loss' "$P/edge-d2.log" || true)"
python3 - << 'PY'
import json, os
p=os.environ["P"]
widths=set()
for line in open(p+"/d2-pub.out"):
    if '"step":"stats"' in line or '"step": "stats"' in line:
        o=json.loads(line)
        for v in o.get("outbound") or []:
            if "frameWidth" in v: widths.add((v.get("frameWidth"), v.get("frameHeight")))
        vo=o.get("videoOut") or {}
        if "frameWidth" in vo: widths.add((vo.get("frameWidth"), vo.get("frameHeight")))
print("D2 encoded", widths)
n=0
for line in open(p+"/d2.raw"):
    if line.startswith("raw-frame"):
        print(line.strip()); n+=1
        if n>=4: break
print("d2_raw", n)
PY
ffprobe -hide_banner -show_entries stream=codec_name,width,height,nb_frames -of compact "$P/d2.ivf" || true
ffmpeg -y -v error -i "$P/d2.ivf" -frames:v 1 "$P/frames/d2.png" || true
file "$P/frames/d2.png" || true
echo "gap done"
