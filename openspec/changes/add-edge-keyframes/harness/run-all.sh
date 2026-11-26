#!/usr/bin/env bash
# Replays spikes S4 (moq-webrtc-embed) and S7 (protected-refusal) for node D (webrtc-edge).
# Local disposable harness only: in-process relay, dummy keys, fake media. Never point it at production.
#   HARNESS=<dir with playwright 1.65.1>  P=<private dir, default /tmp/mjolnir-rtc-private>  ./run-all.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
export P=${P:-/tmp/mjolnir-rtc-private}; mkdir -p "$P"; chmod 700 "$P"
export HARNESS=${HARNESS:-/tmp/mjolnir-rtc-private-pw}
repo=$(cd "$here/../../../.." && pwd)
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$repo/native/mjolnir_relay/target}
(cd "$here/rust" && cargo build --bins && cargo build --release --bin edge) || exit 1
# Fixtures: two colour halves + a tone per participant (fake camera and microphone for Chromium).
cd "$P"
for spec in "alice 0xC83278 0x1EA0A0 1000" "bob 0xE68C14 0x283CC8 600"; do
  set -- $spec
  [ -s "$1.y4m" ] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=$2:size=640x720:rate=30" -f lavfi -i "color=c=$3:size=640x720:rate=30" \
    -filter_complex "[0][1]hstack=inputs=2,format=yuv420p" -t 2 "$1.y4m"
  [ -s "$1.wav" ] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=$4:sample_rate=48000" -t 10 -ac 1 "$1.wav"
done
cd "$here"
L=logs
for vc in VP8 H264 VP9 AV1; do ./claim1-whip.sh $vc > $L/claim1-whip-$vc.log 2>&1; done
./claim1-whip.sh VP8 0 > $L/claim1-whip-VP8-uncapped.log 2>&1
for vc in vp8 h264 vp9 av1; do ./claim2-whep.sh $vc chromium firefox > $L/claim2-whep-$vc.log 2>&1; done
./claim3-room.sh > $L/claim3-room.log 2>&1
./claim4-auth.sh > $L/claim4-auth.log 2>&1
./claim4-auth.sh relay-only > $L/claim4-expiry-relay-only.log 2>&1
./claim5-loss.sh > $L/claim5-loss-simulcast.log 2>&1
./claim6-protected.sh > $L/claim6-protected.log 2>&1
./claim7-cost.sh > $L/claim7-cost.log 2>&1
for f in $L/*.log; do sed -E -i.bak 's/eyJ[A-Za-z0-9_.-]+/[TOKEN]/g' "$f" && rm -f "$f.bak"; done
echo "done. Private outputs (keys, tokens, fixtures, recordings) are in $P: rm -rf $P when finished."
