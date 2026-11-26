#!/bin/sh
# Moving 720p fixture with a burned-in frame counter. Writes under $P, never the repo.
# Usage: moving-720p.sh <seconds> <outfile.y4m>
set -eu
secs=${1:?seconds}
out=${2:?outfile}
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -filter_complex "[0:v]drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='%{n}':x=40:y=40:fontsize=48:fontcolor=white[v]" \
  -map "[v]" -map 1:a -t "$secs" -pix_fmt yuv420p -c:v rawvideo -c:a pcm_s16le "$out"
echo "fixture $out"
