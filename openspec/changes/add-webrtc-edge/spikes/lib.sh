# Sourced by run-all.sh and the step scripts. Local disposable harness only.
#   P   private dir (/tmp/mjolnir-rtc-private*): keys, tokens, fixtures, recordings. Never committed.
#   BIN directory with the spike's `edge` and `harness` binaries.
here=${here:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
logs=$here/logs
BIN=${BIN:-$(cd "$here/../../../../native/mjolnir_relay/target/debug" && pwd)}
P=${P:-/tmp/mjolnir-rtc-private}
LAN=${LAN:-$(ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}')}
EDGE=http://127.0.0.1:8088
PAGES=http://127.0.0.1:18124

pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_grep() { for _ in $(seq 1 120); do grep -q "$2" "$1" 2>/dev/null && return 0; pause 0.25; done; echo "timeout waiting for $2 in $1" >&2; return 1; }
redact() { sed -E -i.bak 's/eyJ[A-Za-z0-9_.-]+/[TOKEN]/g' "$@" && rm -f "${@/%/.bak}"; }
relay_url() { echo "https://$(cat "$P/relay.txt")/?jwt=$1"; }
mint() { "$BIN/harness" mint "$P" "$@"; }

start_relay() {
  rm -f "$P/stop" "$P/relay.txt"
  "$BIN/harness" relay "$P" > "$P/relay.log" 2>&1 &
  echo $! > "$P/relay.pid"; wait_grep "$P/relay.log" "relay up"
}
start_edge() {  # extra args, e.g. --no-expiry-timer
  "$BIN/edge" 127.0.0.1:8088 "$LAN:0" "https://$(cat "$P/relay.txt")/" "$P/verify.json" "$@" > "$P/edge.log" 2>&1 &
  echo $! > "$P/edge.pid"; wait_grep "$P/edge.log" "edge up"
}
stop_edge() { [ -f "$P/edge.pid" ] && kill "$(cat "$P/edge.pid")" 2>/dev/null; rm -f "$P/edge.pid"; pause 0.3; }
start_pages() {
  python3 -m http.server 18124 --bind 127.0.0.1 --directory "$here/pages" > "$P/pages.log" 2>&1 &
  echo $! > "$P/pages.pid"; for _ in $(seq 1 40); do curl -sf "$PAGES/rtc.html" >/dev/null && return 0; pause 0.25; done
}
stop_all() {
  touch "$P/stop"; for f in edge pages relay; do [ -f "$P/$f.pid" ] && kill "$(cat "$P/$f.pid")" 2>/dev/null; rm -f "$P/$f.pid"; done
  pkill -f "$BIN/harness publish" 2>/dev/null; pkill -f "lavfi -i color=c=" 2>/dev/null; true
}

# Native MoQ publisher with fixture content: two colour halves and a tone.
#   pub_native <token> <broadcast> <left> <right> <hz> <h264|vp8|vp9|av1> <seconds>
pub_native() {
  local tok=$1 b=$2 l=$3 r=$4 hz=$5 codec=$6 secs=$7 venc fmt
  case $codec in
    h264) venc=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -g 30 -bf 0); fmt=(-f mp4 -movflags cmaf+frag_keyframe+empty_moov+default_base_moof); pf=fmp4 ;;
    vp8)  venc=(-c:v libvpx -deadline realtime -cpu-used 8 -b:v 1500k -g 30); fmt=(-f matroska -live 1 -cluster_time_limit 1000); pf=mkv ;;
    vp9)  venc=(-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -b:v 1500k -g 30); fmt=(-f matroska -live 1 -cluster_time_limit 1000); pf=mkv ;;
    av1)  venc=(-c:v libsvtav1 -preset 10 -g 30 -svtav1-params tune=0:fast-decode=1); fmt=(-f matroska -live 1 -cluster_time_limit 1000); pf=mkv ;;
  esac
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "color=c=$l:size=640x720:rate=30" -f lavfi -i "color=c=$r:size=640x720:rate=30" \
    -f lavfi -i "sine=frequency=$hz:sample_rate=48000" -filter_complex "[0][1]hstack=inputs=2,format=yuv420p[v]" \
    -map "[v]" -map 2:a -t "$secs" "${venc[@]}" -c:a libopus -b:a 64k -ac 2 "${fmt[@]}" - 2>>"$P/ffmpeg-pub.err" \
    | PUBLISH_FORMAT=$pf "$BIN/harness" publish "$(relay_url "$tok")" "$b" >> "$P/pub-native.log" 2>&1
}
HARNESS=${HARNESS:-/tmp/mjolnir-rtc-private-pw}
