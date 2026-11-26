#!/usr/bin/env bash
# Claim 7: rough edge CPU per WebRTC session at 720p (release build), sampled with ps once a second.
#   viewers:    native H.264 720p ~2 Mbit/s source (testsrc2 + noise) -> K WHEP plays in one Chromium
#   publishers: K Chromium pages publish a noisy 720p camera over WHIP (H.264, ingest cap 2.5 Mbit/s)
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
EDGE_BIN=${EDGE_BIN:-$(cd "$BIN/../release" && pwd)/edge}; export EDGE_BIN
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
[ -s "$P/busy.y4m" ] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30,noise=alls=12:allf=t" -t 2 -pix_fmt yuv420p "$P/busy.y4m"
[ -s "$P/busy.wav" ] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=500:sample_rate=48000" -t 10 -ac 1 "$P/busy.wav"
start_relay; EDGE_INGEST_MBPS=2.5 start_edge; start_pages
EPID=$(cat "$P/edge.pid")
for n in carol erin p0 p1 p2 p3 p4 p5 p6 p7; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES
echo "# claim7 cost $(date -u +%FT%TZ) $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cores; load: $(uptime | sed 's/.*load averages*: //')"
echo "# edge binary: $EDGE_BIN ($(stat -f %z "$EDGE_BIN") bytes)"
sample() {  # sample <label> <seconds>: mean and max %CPU of the edge (100 = one core), RSS
  local s=0 m=0 n=0 v r
  for _ in $(seq 1 "$2"); do v=$(ps -o %cpu= -p "$EPID" | tr -d ' '); r=$(ps -o rss= -p "$EPID" | tr -d ' ')
    s=$(echo "$s + $v" | bc); n=$((n+1)); m=$(echo "if ($v > $m) $v else $m" | bc); pause 1; done
  echo "cpu $1: mean=$(echo "scale=1; $s / $n" | bc)% max=$m% rss=${r}KiB"
}
sample "idle" 5
ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=1280x720:rate=30,noise=alls=12:allf=t" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 200 \
  -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -g 60 -bf 0 -b:v 2M -maxrate 2M -bufsize 1M -c:a libopus -b:a 64k -ac 2 \
  -f mp4 -frag_duration 20000 -movflags cmaf+empty_moov+default_base_moof - 2>/dev/null \
  | "$BIN/harness" publish "$(relay_url "$(cat "$P/carol.tok")")" carol/cam > "$P/c7-pub.out" 2>&1 & PUB=$!
pause 3; sample "native source only (MoQ in, no WebRTC)" 5
for k in 1 4 8; do
  node drive.mjs viewers $k 14 > "$P/c7-v$k.out" 2>&1 & D=$!
  wait_grep "$P/c7-v$k.out" load-ready; pause 3; sample "$k WHEP viewers" 8; wait $D; grep load-done "$P/c7-v$k.out" | cut -c1-600
done
kill $PUB 2>/dev/null; pkill -f "testsrc2=size=1280x720:rate=30,noise" 2>/dev/null; pause 2
for k in 1 4; do
  node drive.mjs publishers $k 22 > "$P/c7-p$k.out" 2>&1 & D=$!
  wait_grep "$P/c7-p$k.out" load-ready; pause 10; sample "$k WHIP publishers" 8; wait $D; grep load-done "$P/c7-p$k.out" | cut -c1-600
done
echo "# UDP sockets held by the edge (one shared media port):"; lsof -nP -a -p "$EPID" -i UDP | awk 'NR>1{print $8, $9}' | sort | uniq -c
