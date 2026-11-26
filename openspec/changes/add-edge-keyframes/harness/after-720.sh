#!/usr/bin/env bash
# After rows on the same 1280x720 moving fixture, cap, route, and toolchain as before-720.sh.
# KEYFRAME_POLICY is the named harness hook: off, trial (period 2s), saturated (period 1s).
set -u
here=$(cd "$(dirname "$0")" && pwd)
export LAN=${LAN:?set LAN}
source "$here/lib.sh"
export P=${P:-/tmp/kf-after720}
export HARNESS=${HARNESS:-/tmp/kf-pw}
mkdir -p "$P" "$here/logs"
chmod 700 "$P"
cd "$HARNESS" && cp -f "$here/drive.mjs" "$here/pages/rtc.js" . 2>/dev/null || cp -f "$here/drive.mjs" .
FONT=${FONT:-/usr/share/fonts/noto/NotoSans-Regular.ttf}
trap 'stop_all; [ -n "${PX:-}" ] && kill "$PX" 2>/dev/null || true; [ -n "${PUB:-}" ] && kill "$PUB" 2>/dev/null || true; [ -n "${PROBE:-}" ] && kill "$PROBE" 2>/dev/null || true' EXIT
echo "platform=$(uname -srm) rustc=$(rustc --version)"
echo "pin=4a6f52248 policy=${KEYFRAME_POLICY:-trial} moq-webrtc=vendor patch"
echo "lan=$LAN chromium=${CHROMIUM_BIN:-unset}"
echo "fixture=testsrc2 1280x720 rate=30 drawtext frame counter font=$FONT tone=440Hz cap=1500k gop=30"
export KEYFRAME_POLICY=${KEYFRAME_POLICY:-trial}
start_relay || { echo "relay failed"; cat "$P/relay.log"; exit 1; }
start_edge || { echo "edge failed"; cat "$P/edge.log"; exit 1; }
grep -q "edge up" "$P/edge.log" || { echo "edge not up"; cat "$P/edge.log"; exit 1; }
start_pages || exit 1
for n in carol erin frank grace heidi; do mint r1 "$n" 1200 > "$P/$n.tok"; done

pub_moving() {
  local tok=$1 secs=$2 codec=$3 gop=${4:-30}
  local venc fmt pf
  case $codec in
    h264) venc=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -g "$gop" -bf 0); fmt=(-f mp4 -frag_duration 20000 -movflags cmaf+empty_moov+default_base_moof); pf=fmp4 ;;
    vp8)  venc=(-c:v libvpx -deadline realtime -cpu-used 8 -b:v 1500k -g "$gop"); fmt=(-f matroska -live 1 -cluster_time_limit 20 -cluster_size_limit 4096); pf=mkv ;;
    *) echo "bad codec $codec"; return 1 ;;
  esac
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -filter_complex "[0:v]drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white[v]" \
    -map "[v]" -map 1:a -t "$secs" "${venc[@]}" -c:a libopus -b:a 64k -ac 1 "${fmt[@]}" - \
    2>>"$P/ffmpeg.err" | PUBLISH_FORMAT=$pf "$BIN/harness" publish "$(relay_url "$tok")" carol/cam >>"$P/pub.log" 2>&1
}

echo "## A WHEP first presented frame, 10 joins, h264 and vp8, policy=$KEYFRAME_POLICY"
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

echo "## B decodable first frame and lag versus a live probe"
pub_moving "$(cat "$P/carol.tok")" 40 vp8 & PUB=$!
pause 4
url=$(relay_url "$(cat "$P/erin.tok")")
python3 -u - "$url" << 'PY' &
import os, subprocess, sys, time
url = sys.argv[1]
bin, p = os.environ["BIN"], os.environ["P"]
t0 = time.time()
proc = subprocess.Popen([os.path.join(bin, "harness"), "raw", url, "carol/cam", "30", f"{p}/b-probe"], stdout=subprocess.PIPE, text=True)
open(f"{p}/b-probe.stamp","w").write(f"{t0}\n")
out = open(f"{p}/b-probe.live","w")
for line in proc.stdout:
    if line.startswith("raw-frame"):
        out.write(f"{time.time():.3f} {line}")
        out.flush()
proc.wait()
PY
PROBE=$!
pause 3
python3 -u - "$url" << 'PY'
import os, subprocess, sys, time
url = sys.argv[1]
bin, p = os.environ["BIN"], os.environ["P"]
t0 = time.time()
proc = subprocess.Popen([os.path.join(bin, "harness"), "raw", url, "carol/cam", "4", f"{p}/b-join"], stdout=subprocess.PIPE, text=True)
out = open(f"{p}/b-join.live","w")
for line in proc.stdout:
    if line.startswith("raw-frame"):
        out.write(f"{time.time():.3f} {line}")
        out.flush()
proc.wait()
print(f"B joiner_wall0={t0:.3f}")
PY
kill "$PROBE" 2>/dev/null || true
wait "$PROBE" 2>/dev/null || true
PROBE=
ffprobe -hide_banner -show_entries stream=codec_name,width,height,nb_frames,duration -of compact "$P/b-join.ivf" || echo "B ivf missing"
ffmpeg -y -v error -i "$P/b-join.ivf" -frames:v 1 "$P/b-join.png" || true
python3 - << 'PY'
import os, re
p=os.environ["P"]
def rows(path):
    out=[]
    if not os.path.exists(path):
        return out
    for line in open(path):
        m=re.search(r"^(\d+\.\d+) raw-frame .* media=(\S+) ", line)
        if not m: continue
        media=m.group(2).rstrip(",")
        # Duration debug: 4s, 4500ms, 4.5s
        if media.endswith("ms"):
            sec=float(media[:-2])/1000
        elif media.endswith("µs") or media.endswith("us"):
            sec=float(media[:-2])/1e6
        elif media.endswith("s"):
            sec=float(media[:-1])
        else:
            continue
        out.append((float(m.group(1)), sec))
    return out
probe, join = rows(p+"/b-probe.live"), rows(p+"/b-join.live")
print(f"B probe_frames={len(probe)} join_frames={len(join)}")
if join and probe:
    t, media = join[0]
    newest = max((m for ts,m in probe if ts<=t), default=None)
    lag = None if newest is None else newest-media
    print(f"B first_decodable_media_s={media:.3f} probe_newest_s={newest} lag_s={lag}")
else:
    print("B lag=missing")
PY
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## C export vp8"
pub_moving "$(cat "$P/carol.tok")" 16 vp8 & PUB=$!
pause 4
timeout 20 "$BIN/harness" export "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 4 "$P/c-export" || echo "C export failed"
ls -l "$P"/c-export* || true
ffprobe -hide_banner -show_entries stream=codec_name,width,height -of compact "$P"/c-export* 2>/dev/null | head || true
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## E viewer storm negative control: 1 then 4 viewers, 20s, policy=$KEYFRAME_POLICY"
pub_moving "$(cat "$P/carol.tok")" 50 vp8 & PUB=$!
pause 4
mark=$(wc -l < "$P/edge.log" || echo 0)
VIEWER_NAMES=erin node drive.mjs viewers 1 20 > "$P/e1.out" 2>&1 || echo "E one viewer failed"
VIEWER_NAMES=erin,frank,grace,heidi node drive.mjs viewers 4 20 > "$P/e4.out" 2>&1 || echo "E four viewers failed"
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=
python3 - "$mark" << 'PY'
import os, sys
p=os.environ["P"]+"/edge.log"
start=int(sys.argv[1])
lines=open(p).read().splitlines()[start:]
gate=[ln for ln in lines if "ingest keyframe gate" in ln]
viewer=[ln for ln in gate if "viewer" in ln.lower()]
peer=[ln for ln in lines if "keyframe request from peer" in ln]
print(f"E gate_lines={len(gate)} viewer_cause_lines={len(viewer)} peer_pli_lines={len(peer)}")
for ln in gate[:12]:
    print("E", ln)
PY

echo "## F three probe-boundary runs are separate invocations; this process is policy=$KEYFRAME_POLICY"
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
print(f"F policy={os.environ.get('KEYFRAME_POLICY')} groups={len(groups)} frames={sum(len(v) for v in groups.values())} key_bytes={key} other_bytes={other} share={(key/total if total else 0):.4f} quality_difference=missing cap=1500k gop=30")
PY
ffprobe -hide_banner -show_entries stream=codec_name,width,height,nb_frames,duration -of compact "$P/f.ivf" || true
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=

echo "## D1 viewer-leg blackout only (burst-dir client). Publisher leg is left alone."
stop_edge
EDGE_ADVERTISE=$LAN:40001 "$BIN/edge" 127.0.0.1:8088 "$LAN:40000" "https://$(cat "$P/relay.txt")/" "$P/verify.json" > "$P/edge.log" 2>&1 &
echo $! > "$P/edge.pid"
wait_grep "$P/edge.log" "edge up" || { echo "D1 edge failed"; exit 1; }
python3 -u "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 --burst-after 2 --burst 1.5 --burst-dir client > "$P/d1.out" 2>&1 & PX=$!
pub_moving "$(cat "$P/carol.tok")" 25 vp8 & PUB=$!
pause 2
node drive.mjs join chromium carol/cam - erin || echo "D1 join failed"
kill "$PX" 2>/dev/null || true
wait "$PX" 2>/dev/null || true
echo "D1 proxy $(tr '\n' ' ' < "$P/d1.out")"
kill "$PUB" 2>/dev/null || true
wait "$PUB" 2>/dev/null || true
PUB=
PX=

echo "## D2 publisher-leg blackout (burst-dir edge) plus loss-cause PLI and post-burst keyframe"
python3 -u "$here/lossy.py" "$LAN:40001" "$LAN:40000" 0 0 --burst-after 3 --burst 1.5 --burst-dir edge > "$P/d2.out" 2>&1 & PX=$!
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -vf "drawtext=fontfile=${FONT}:text=%{n}:x=40:y=40:fontsize=48:fontcolor=white" \
  -t 2 -pix_fmt yuv420p "$P/carol.y4m"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 12 -ac 1 "$P/carol.wav"
node drive.mjs pub carol carol/cam VP8 12 carol > "$P/d2-pub.out" 2>&1 & D=$!
pause 2
python3 -u - "$(relay_url "$(cat "$P/erin.tok")")" << 'PY'
import os, subprocess, sys, time
url=sys.argv[1]
bin,p=os.environ["BIN"],os.environ["P"]
proc=subprocess.Popen([os.path.join(bin,"harness"),"raw",url,"carol/cam","10",f"{p}/d2"], stdout=subprocess.PIPE, text=True)
out=open(f"{p}/d2.stamped","w")
for line in proc.stdout:
    if line.startswith("raw-frame"):
        out.write(f"{time.time():.3f} {line}"); out.flush()
proc.wait()
PY
wait "$D" || true
echo "D2 proxy $(tr '\n' ' ' < "$P/d2.out")"
python3 - << 'PY'
import os, re
p=os.environ["P"]
text=open(p+"/d2.out").read()
print("D2 proxy_file", text.strip())
edge=open(p+"/edge.log").read().splitlines()
loss=[ln for ln in edge if "ingest keyframe gate" in ln and "loss" in ln]
print(f"D2 loss_gate_lines={len(loss)}")
for ln in loss[:8]:
    print("D2", ln)
rows=[]
for line in open(p+"/d2.stamped"):
    m=re.search(r"^(\d+\.\d+) raw-frame .* group_start=(\d+) .* media=(\S+)", line)
    if m:
        rows.append((float(m.group(1)), int(m.group(2)), m.group(3)))
print(f"D2 stamped_frames={len(rows)}")
if rows:
    # a new group after a gap is the post-burst keyframe candidate
    gaps=[]
    for i in range(1,len(rows)):
        dt=rows[i][0]-rows[i-1][0]
        if dt>0.4 and rows[i][1]!=rows[i-1][1]:
            gaps.append((dt, rows[i]))
    print("D2 group_gaps", gaps[:4])
PY
kill "$PX" 2>/dev/null || true
echo done
