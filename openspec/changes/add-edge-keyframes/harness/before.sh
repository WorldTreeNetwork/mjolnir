#!/usr/bin/env bash
# Unpatched before-numbers for design D6 rows A B C D1 D2 F.
# Policy is the pin (off). Framework or Darwin; never a production relay.
set -u
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"
export P=${P:-/tmp/kf-before}
export HARNESS=${HARNESS:-/tmp/kf-pw}
mkdir -p "$P" "$here/logs"
chmod 700 "$P"
cd "$HARNESS" && cp "$here/drive.mjs" .
trap 'stop_all; [ -n "${PX:-}" ] && kill $PX 2>/dev/null || true' EXIT
echo "platform=$(uname -srm) rustc=$(rustc --version) pin=4a6f52248 policy=off"
echo "cargo_profile_dev_debug=${CARGO_PROFILE_DEV_DEBUG:-unset} cargo_incremental=${CARGO_INCREMENTAL:-unset}"
echo "chromium=${CHROMIUM_BIN:-playwright-default} boundary=probe raw-frame payload bytes and browser firstPresentedMs"
start_relay; start_edge; start_pages
for n in carol erin; do mint r1 $n 900 > "$P/$n.tok"; done
# Synthetic two-colour fixture, not a camera.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0x28B43C:size=640x360:rate=30" -f lavfi -i "color=c=0x7828AA:size=640x360:rate=30" \
  -filter_complex "[0][1]hstack=inputs=2,format=yuv420p" -t 2 "$P/carol.y4m"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 8 -ac 1 "$P/carol.wav"
echo "fixture=synthetic 1280x360 two-colour plus 440Hz"
echo "## A WHEP first presented frame"
for vc in h264 vp8; do
  ( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 "$vc" 90 ) &
  echo $! > "$P/pub.pid"
  pause 3
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "A $vc join $i"
    node drive.mjs join chromium carol/cam - erin || echo "A $vc join $i failed"
  done
  kill "$(cat "$P/pub.pid")" 2>/dev/null || true
  pause 1
done
echo "## B MoQ late subscribe to first raw-frame"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 80 ) &
echo $! > "$P/pub.pid"
pause 3
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "B join $i"
  url=$(relay_url "$(cat "$P/erin.tok")")
  python3 - "$i" "$url" << 'PY'
import subprocess, time, sys, os
i, url = sys.argv[1], sys.argv[2]
bin, p = os.environ["BIN"], os.environ["P"]
t0 = time.time()
proc = subprocess.Popen([os.path.join(bin, "harness"), "raw", url, "carol/cam", "3", f"{p}/b-{i}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
first = None
for line in proc.stdout:
    if line.startswith("raw-frame"):
        first = time.time() - t0
        print(f"B first_raw_s={first:.3f} {line.strip()}")
        proc.kill()
        break
proc.wait()
if first is None:
    print(f"B join {i} no raw-frame")
PY
done
kill "$(cat "$P/pub.pid")" 2>/dev/null || true
echo "## C export"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 20 ) &
echo $! > "$P/pub.pid"
pause 3
timeout 15 "$BIN/harness" export "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 4 "$P/c-export" || echo "C export failed"
ls -l "$P"/c-export* 2>/dev/null || true
kill "$(cat "$P/pub.pid")" 2>/dev/null || true
echo "## F policy off, probe bytes"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 20 ) &
echo $! > "$P/pub.pid"
pause 3
timeout 15 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" carol/cam 8 "$P/f" > "$P/f.raw" 2>"$P/f.err" || true
python3 - << 'PY'
import os
p=os.environ["P"]+"/f.raw"
key=delta=0
groups=set()
for line in open(p):
    if not line.startswith("raw-frame"): continue
    g=int(line.split("group_start=")[1].split()[0])
    b=int(line.split("bytes=")[1].split()[0])
    groups.add(g)
    if g==0 and key==0: key+=b
    else: delta+=b
print(f"F groups={len(groups)} key_bytes={key} other_bytes={delta} share={(key/(key+delta) if key+delta else 0):.4f} quality=missing")
PY
kill "$(cat "$P/pub.pid")" 2>/dev/null || true
echo "## D1 D2 blackout needs the loss proxy; recorded in a second pass if A succeeded"
echo "done"
