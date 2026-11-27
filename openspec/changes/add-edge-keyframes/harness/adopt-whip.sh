#!/usr/bin/env bash
# WHIP-origin adoption rows on one route. Publisher is Chromium fake-capture of the
# 1280x720 testsrc2 y4m, through the edge, not native MoQ publish.
# Usage: LAN=10.x BIN=/tmp/kf-after/debug KEYFRAME_POLICY=off|trial|saturated ./adopt-whip.sh A|B|C|D1|D2|E|F
set -u
here=$(cd "$(dirname "$0")" && pwd)
export LAN=${LAN:?set LAN}
source "$here/lib.sh"
export P=${P:-/tmp/kf-adopt}
export HARNESS=${HARNESS:-/tmp/kf-pw}
export CHROMIUM_BIN=${CHROMIUM_BIN:-/usr/bin/chromium}
ROW=${1:?row}
mkdir -p "$P" "$here/logs"
chmod 700 "$P"
cd "$HARNESS"
cp -f "$here/drive.mjs" "$here/pages/rtc.js" . 2>/dev/null || cp -f "$here/drive.mjs" .
FONT=${FONT:-/usr/share/fonts/noto/NotoSans-Regular.ttf}
trap 'stop_all; [ -n "${PX:-}" ] && kill "$PX" 2>/dev/null || true' EXIT
echo "git=$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "platform=$(uname -srm) rustc=$(rustc --version)"
echo "pin=4a6f52248 policy=${KEYFRAME_POLICY:-off} lan=$LAN chromium=$($CHROMIUM_BIN --version | head -1)"
echo "route=chromium WHIP -> edge 127.0.0.1:8088 -> in-process relay -> readers"
echo "fixture=testsrc2 1280x720 rate=30 drawtext counter tone=440Hz cap_ingest=2.5 edge_advertise=$LAN"
export KEYFRAME_POLICY=${KEYFRAME_POLICY:-off}

if [ ! -f "$P/alice.y4m" ]; then
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=30" \
    -vf "drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white" \
    -frames:v 240 -pix_fmt yuv420p "$P/alice.y4m"
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 8 "$P/alice.wav"
fi

start_relay || { echo relay_failed; cat "$P/relay.log"; exit 1; }
# Advertise the loss-proxy port when LOSS_PROXY=1, else the edge's own port.
if [ "${LOSS_PROXY:-}" = 1 ]; then
  python3 "$here/lossy.py" "$LAN:40001" "127.0.0.1:40000" "${LOSS_CLIENT:-0}" "${LOSS_EDGE:-0}" \
    ${BURST:+--burst "$BURST"} ${BURST_AFTER:+--burst-after "$BURST_AFTER"} ${BURST_DIR:+--burst-dir "$BURST_DIR"} \
    > "$P/proxy.log" 2>&1 &
  PX=$!
  export EDGE_ADVERTISE="$LAN:40001"
fi
start_edge || { echo edge_failed; cat "$P/edge.log"; exit 1; }
grep -q "edge up" "$P/edge.log" || { echo edge_not_up; cat "$P/edge.log"; exit 1; }
start_pages || exit 1
for n in alice erin frank dave grace heidi; do mint r1 "$n" 1800 > "$P/$n.tok"; done

case "$ROW" in
  A)
    for vc in H264 VP8; do
      node drive.mjs pub alice alice/cam "$vc" 200 > "$P/pub-$vc.out" 2>&1 &
      PUB=$!
      for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-$vc.out" 2>/dev/null && break; pause 0.5; done
      pause 2
      for i in 1 2 3 4 5 6 7 8 9 10; do
        echo "A $vc join $i"
        node drive.mjs join chromium alice/cam - erin || echo "A $vc join $i failed"
      done
      kill "$PUB" 2>/dev/null || true
      wait "$PUB" 2>/dev/null || true
      pause 1
    done
    ;;
  B)
    node drive.mjs pub alice alice/cam VP8 200 > "$P/pub-B.out" 2>&1 &
    PUB=$!
    for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-B.out" 2>/dev/null && break; pause 0.5; done
    pause 3
    url=$(relay_url "$(cat "$P/erin.tok")")
    for i in 1 2 3 4 5 6 7 8 9 10; do
      echo "B join $i wall=$(date +%s.%N)"
      timeout 8 "$BIN/harness" raw "$url" alice/cam 3 "$P/b-$i" || echo "B join $i failed"
    done
    kill "$PUB" 2>/dev/null || true
    ;;
  C)
    for vc in VP8 VP9 AV1; do
      echo "## C $vc"
      node drive.mjs pub alice alice/cam "$vc" 20 > "$P/pub-$vc.out" 2>&1 &
      PUB=$!
      for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-$vc.out" 2>/dev/null && break; pause 0.5; done
      pause 2
      timeout 20 "$BIN/harness" export "$(relay_url "$(cat "$P/frank.tok")")" alice/cam 6 "$P/c-$vc.mkv" > "$P/c-$vc.out" 2>&1 || echo "C $vc export failed"
      kill "$PUB" 2>/dev/null || true
      wait "$PUB" 2>/dev/null || true
      ffprobe -hide_banner "$P/c-$vc.mkv" 2>&1 | head -20 || true
    done
    ;;
  D1|D2)
    node drive.mjs pub alice alice/cam VP8 40 > "$P/pub-$ROW.out" 2>&1 &
    PUB=$!
    for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-$ROW.out" 2>/dev/null && break; pause 0.5; done
    if [ "$ROW" = D1 ]; then
      export STRIP=1
      node drive.mjs join chromium alice/cam - erin || echo D1_join_failed
    else
      pause 2
      timeout 12 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" alice/cam 8 "$P/d2" || echo D2_raw_failed
    fi
    kill "$PUB" 2>/dev/null || true
    echo "## gate lines"
    rg -n "ingest keyframe gate|keyframe request" "$P/edge.log" || true
    echo "## proxy"
    kill "$PX" 2>/dev/null || true
    wait "$PX" 2>/dev/null || true
    PX=
    cat "$P/proxy.log" || true
    ;;
  E)
    node drive.mjs pub alice alice/cam VP8 30 > "$P/pub-E.out" 2>&1 &
    PUB=$!
    for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-E.out" 2>/dev/null && break; pause 0.5; done
    pause 1
    node drive.mjs join chromium alice/cam - erin > "$P/e1.out" 2>&1 &
    pause 20
    echo "## one viewer"
    rg -n "keyframe request|ingest keyframe gate" "$P/edge.log" || true
    wait || true
    kill "$PUB" 2>/dev/null || true
    ;;
  F)
    node drive.mjs pub alice alice/cam VP8 16 > "$P/pub-F.out" 2>&1 &
    PUB=$!
    for _ in $(seq 1 40); do grep -q '"step":"publish"' "$P/pub-F.out" 2>/dev/null && break; pause 0.5; done
    timeout 14 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" alice/cam 8 "$P/f" || true
    kill "$PUB" 2>/dev/null || true
    echo "## gate lines"
    rg -n "ingest keyframe gate" "$P/edge.log" || true
    python3 - << 'PY'
import os,re
p=os.environ["P"]
text=open(p+"/f.out").read() if os.path.exists(p+"/f.out") else ""
# harness raw prints group lines; fall back to ivf size
print("raw_log_bytes", os.path.getsize(p+"/f.out") if os.path.exists(p+"/f.out") else 0)
PY
    ;;
  *) echo "unknown row $ROW"; exit 2 ;;
esac
echo "## edge up check"
rg -n "edge up|ingest keyframe" "$P/edge.log" | head -40 || true
echo ROW_DONE "$ROW" policy="${KEYFRAME_POLICY}"
