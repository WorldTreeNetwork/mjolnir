#!/usr/bin/env bash
# Full unpatched before rows on one route. Moving 1280x720 testsrc2, burned frame counter, 440 Hz.
# Requires LAN, BIN, HARNESS, CHROMIUM_BIN. Framework Arch is not Ubuntu.
set -u
here=$(cd "$(dirname "$0")" && pwd)
export LAN=${LAN:?set LAN to the host address the edge should advertise}
source "$here/lib.sh"
export P=${P:-/tmp/kf-before720}
export HARNESS=${HARNESS:-/tmp/kf-pw}
mkdir -p "$P" "$here/logs"
chmod 700 "$P"
cd "$HARNESS" && cp -f "$here/drive.mjs" .
FONT=${FONT:-/usr/share/fonts/noto/NotoSans-Regular.ttf}
trap 'stop_all; [ -n "${PX:-}" ] && kill "$PX" 2>/dev/null || true; [ -n "${PUB:-}" ] && kill "$PUB" 2>/dev/null || true' EXIT
echo "platform=$(uname -srm) rustc=$(rustc --version)"
echo "pin=4a6f52248 policy=off moq-webrtc=git not vendored"
echo "lan=$LAN chromium=${CHROMIUM_BIN:-unset}"
echo "cargo_profile_dev_debug=${CARGO_PROFILE_DEV_DEBUG:-unset} cargo_incremental=${CARGO_INCREMENTAL:-unset}"
echo "fixture=testsrc2 1280x720 rate=30 drawtext frame counter font=$FONT tone=440Hz"
echo "boundary=WHEP POST to requestVideoFrameCallback; MoQ raw-frame payload bytes; ffmpeg decode of the ivf"
start_relay || { echo "relay failed"; cat "$P/relay.log"; exit 1; }
start_edge || { echo "edge failed"; cat "$P/edge.log"; exit 1; }
grep -q "edge up" "$P/edge.log" || { echo "edge not up"; cat "$P/edge.log"; exit 1; }
echo "edge_up=yes"
start_pages || { echo "pages failed"; exit 1; }
for n in carol erin; do mint r1 "$n" 1200 > "$P/$n.tok"; done

pub_moving() {
  local tok=$1 secs=$2 codec=$3
  local venc fmt pf
  case $codec in
    h264) venc=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -g 30 -bf 0); fmt=(-f mp4 -frag_duration 20000 -movflags cmaf+empty_moov+default_base_moof); pf=fmp4 ;;
    vp8)  venc=(-c:v libvpx -deadline realtime -cpu-used 8 -b:v 1500k -g 30); fmt=(-f matroska -live 1 -cluster_time_limit 20 -cluster_size_limit 4096); pf=mkv ;;
    *) echo "bad codec $codec"; return 1 ;;
  esac
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -filter_complex "[0:v]drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white[v]" \
    -map "[v]" -map 1:a -t "$secs" "${venc[@]}" -c:a libopus -b:a 64k -ac 1 "${fmt[@]}" - \
    2>>"$P/ffmpeg.err" | PUBLISH_FORMAT=$pf "$BIN/harness" publish "$(relay_url "$tok")" carol/cam >>"$P/pub.log" 2>&1
}

echo "## A WHEP first presented frame, 10 joins, h264 and vp8"
for vc in h264 vp8; do
  pub_moving "$(cat "$P/carol.tok")" 220 "$vc" & PUB=$!
  pause 4
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "A $vc join $i"
    node drive.mjs join chromium carol/cam - erin || echo "A $vc join $i failed"
  done
  kill "$PUB" 2>/dev/null || true
  wait "$PUB" 2>/dev/null || true
  PUB=
  pause 1
done

echo "## B MoQ late subscribe, 10, vp8, then decode one ivf"
pub_moving "$(cat "$P/carol.tok")" 80 vp8 & PUB=$!
pause 4
for i in 1 2 3 4 5 6 7 8 9 10; do
  url=$(relay_url "$(cat "$P/erin.tok")")
  python3 - "$i" "$url" << 'PY'
import os, subprocess, time, sys
i, url = sys.argv[1], sys.argv[2]
bin, p = os.environ["BIN"], os.environ["P"]
t0 = time.time()
proc = subprocess.Popen([os.path.join(bin, "harness"), "raw", url, "carol/cam", "4", f"{p}/b-{i}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
hit = False
for line in proc.stdout:
    if line.startswith("raw-frame"):
        print(f"B first_raw_s={time.time()-t0:.3f} {line.strip()}")
        proc.kill(); hit = True; break
proc.wait()
if not hit:
    print(f"B join {i} no raw-frame")
PY
done
echo "## B decode: one raw runs to its deadline so the ivf is written (a kill at the first line drops it)"
timeout 15 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 3 "$P/b-decode" > "$P/b-decode.raw" 2>"$P/b-decode.err" || true
ffprobe -hide_banner -show_entries stream=codec_name,width,height,nb_frames,duration -of compact "$P/b-decode.ivf" || true
mkdir -p "$P/frames"
ffmpeg -y -v error -i "$P/b-decode.ivf" -frames:v 1 "$P/frames/b0.png" || true
identify "$P/frames/b0.png" 2>/dev/null || file "$P/frames/b0.png" || true
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## C export vp8"
pub_moving "$(cat "$P/carol.tok")" 16 vp8 & PUB=$!
pause 4
timeout 20 "$BIN/harness" export "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 4 "$P/c-export" || echo "C export failed"
ls -l "$P"/c-export* || true
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## F policy off probe bytes, 8s vp8"
pub_moving "$(cat "$P/carol.tok")" 16 vp8 & PUB=$!
pause 4
timeout 20 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 8 "$P/f" > "$P/f.raw" 2>"$P/f.err" || true
python3 - << 'PY'
import os
p=os.environ["P"]+"/f.raw"
groups={}
for line in open(p):
    if not line.startswith("raw-frame"):
        continue
    g=int(line.split("group_start=")[1].split()[0])
    b=int(line.split("bytes=")[1].split()[0])
    groups.setdefault(g, []).append(b)
key=sum(v[0] for v in groups.values() if v)
other=sum(sum(v[1:]) for v in groups.values())
total=key+other
print(f"F groups={len(groups)} frames={sum(len(v) for v in groups.values())} key_bytes={key} other_bytes={other} share={(key/total if total else 0):.4f} quality=missing cap=1500k gop=30")
PY
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## D1 viewer blackout 1.5s at join, same edge address via loss proxy"
stop_edge
EDGE_ADVERTISE=$LAN:40001 "$BIN/edge" 127.0.0.1:8088 "$LAN:40000" "https://$(cat "$P/relay.txt")/" "$P/verify.json" > "$P/edge.log" 2>&1 &
echo $! > "$P/edge.pid"
wait_grep "$P/edge.log" "edge up" || { echo "D1 edge failed"; exit 1; }
export STRIP=1
python3 "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 --burst 1.5 > "$P/d1.out" 2>&1 & PX=$!
pub_moving "$(cat "$P/carol.tok")" 25 vp8 & PUB=$!
pause 3
echo "D1 burst-at-join"
node drive.mjs join chromium carol/cam - erin || echo "D1 join failed"
kill "$PX" 2>/dev/null || true
wait "$PX" 2>/dev/null || true
echo "D1 proxy $(cat "$P/d1.out" 2>/dev/null || true)"
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=
PX=

echo "## D2 publisher-side 1.5s blackout: Chromium WHIP through the loss proxy, MoQ reader on the relay"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -vf "drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white" \
  -t 2 -pix_fmt yuv420p "$P/carol.y4m"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 8 -ac 1 "$P/carol.wav"
python3 -u "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 --burst-after 3 --burst 1.5 > "$P/d2.out" 2>&1 & PX=$!
node drive.mjs pub carol carol/cam VP8 10 carol > "$P/d2-pub.out" 2>&1 & D=$!
pause 3
timeout 18 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 8 "$P/d2" > "$P/d2.raw" 2>"$P/d2.err" || true
wait "$D" || true
echo "D2 proxy $(cat "$P/d2.out" 2>/dev/null || true)"
echo "D2 loss-cause lines: $(rg -c 'loss-cause|cause=loss' "$P/edge.log" || true)"
echo "D2 pli lines: $(rg -c -i 'pli|keyframe' "$P/edge.log" || true)"
python3 - << 'PY'
import os
p=os.environ["P"]+"/d2.raw"
n=0
for line in open(p):
    if line.startswith("raw-frame"):
        print(line.strip()); n+=1
        if n>=8: break
print(f"D2 raw_frames_shown={n}")
PY
kill "$PX" 2>/dev/null || true
echo "done edge_bound=yes fixture=1280x720-moving"

