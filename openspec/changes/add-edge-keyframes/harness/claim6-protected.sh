#!/usr/bin/env bash
# Claim 6 / spike S7: protected (moq-e2ee) broadcasts and the WebRTC edge.
#  A. alice publishes a protected broadcast at alice/<credential path>: real H.264 + Opus (fixture), each
#     track bridged frame by frame into moq-e2ee as the add-call-e2ee page does. Dummy secret 32 x 0x11.
#     erin asks the edge to play it over WHEP (Chromium), and also reads it as a plain MoQ subscriber.
#  B. bob publishes plaintext over WHIP (bob/cam). A credential holder discovers and tries to decrypt it.
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
rm -f "$P/protected-path.txt" "$P"/c6-*; start_relay; EDGE_INGEST_MBPS=2.5 start_edge; start_pages
for n in alice bob erin; do mint r1 $n 600 > "$P/$n.tok"; done
export P EDGE PAGES
echo "# claim6 protected refusal $(date -u +%FT%TZ)"
ffmpeg -hide_banner -loglevel error -re -f lavfi -i "color=c=0xC83278:size=640x720:rate=30" -f lavfi -i "color=c=0x1EA0A0:size=640x720:rate=30" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000" -filter_complex "[0][1]hstack=inputs=2,format=yuv420p[v]" -map "[v]" -map 2:a -t 40 \
  -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -g 30 -bf 0 -c:a libopus -b:a 64k -ac 2 \
  -f mp4 -frag_duration 20000 -movflags cmaf+empty_moov+default_base_moof - 2>/dev/null \
  | "$BIN/harness" protected-pub "$P" "$(relay_url "$(cat "$P/alice.tok")")" alice > "$P/c6-pub.out" 2>&1 & PUB=$!
wait_grep "$P/c6-pub.out" "protected publish"; PROT=$(cat "$P/protected-path.txt")
echo "## A. protected publisher"; grep "protected publish" "$P/c6-pub.out" | sed -E 's#alice/[A-Za-z0-9_-]{16,}#alice/<opaque>#'
pause 2
echo "## A1. WHEP play of alice/<opaque> in Chromium (erin, valid room token)"
node drive.mjs play chromium "$PROT" - 6 0xC83278 0x1EA0A0 1000 erin 2>&1 | sed -E "s#${PROT//\//\\/}#alice/<opaque>#g"; echo "exit=$?"
echo "## A2. the same request with curl, timed"
SDP=$(printf 'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n')
/usr/bin/time -p curl -s -o "$P/c6.body" -w 'status=%{http_code}\n' -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/erin.tok")" --data "$SDP" "$EDGE/whep/r1/$PROT" 2>&1 | grep -E "status|real"
echo "## A3. plain MoQ subscriber without the credential (erin) on alice/<opaque>"
timeout 20 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" "$PROT" 4 "$P/c6-erin.x" 2>&1 | grep -E "^raw|Error|error" | sed -E "s#${PROT//\//\\/}#alice/<opaque>#g"
echo "## B. bob publishes plaintext over WHIP (bob/cam); a credential holder discovers and forces decryption"
node drive.mjs pub bob bob/cam VP8 14 > "$P/c6-bob.out" 2>&1 & D=$!
wait_grep "$P/c6-bob.out" '"step":"publish"'; head -1 "$P/c6-bob.out"; pause 2
timeout 60 "$BIN/harness" protected-read "$(relay_url "$(cat "$P/alice.tok")")" bob bob/cam 3 2>&1 | grep protected-read | sed -E 's#alice/[A-Za-z0-9_-]{16,}#alice/<opaque>#g'
echo "## B2. control: the plaintext WHIP broadcast is readable without any credential"
timeout 20 "$BIN/harness" raw "$(relay_url "$(cat "$P/erin.tok")")" bob/cam 4 "$P/c6-bobplain.x" 2>&1 | grep "^raw"
python3 "$here/analyze.py" 0xE68C14 0x283CC8 600 "$P/c6-bobplain.ivf" "$P/c6-bobplain.opus"
wait $D; kill $PUB 2>/dev/null
echo "## edge log"; grep -E "session accepted|session ended|refused" "$P/edge.log" | cut -c1-300 | sed -E 's#alice/[A-Za-z0-9_-]{16,}#alice/<opaque>#g'
