#!/usr/bin/env bash
# Claim 4: authorization at the edge, then a room token expiring mid-session.
#   ./claim4-auth.sh            refusals (browser + curl) and expiry with the edge's own timer
#   ./claim4-auth.sh relay-only expiry with --no-expiry-timer: only the relay ends the edge's session
set -u
here=$(cd "$(dirname "$0")" && pwd); source "$here/lib.sh"
MODE=${1:-full}
cd "$HARNESS" && cp "$here/drive.mjs" .
trap stop_all EXIT
start_relay
if [ "$MODE" = relay-only ]; then start_edge --no-expiry-timer; else start_edge; fi
start_pages
for n in alice carol; do mint r1 $n 600 > "$P/$n.tok"; done
mint r2 alice 600 > "$P/alice-r2.tok"
"$BIN/harness" keygen "$P/other-private.json"; MINT_KEYFILE=$P/other-private.json mint r1 alice 600 > "$P/forged.tok"
mint r1 alice 1 > "$P/expired.tok"; mint r1 alice 25 > "$P/alice-ttl.tok"
export P EDGE PAGES
echo "# claim4 auth mode=$MODE $(date -u +%FT%TZ)"
( pub_native "$(cat "$P/carol.tok")" carol/cam 0x28B43C 0x7828AA 440 vp8 60 ) & PUB=$!
pause 2.5
if [ "$MODE" != relay-only ]; then
  echo "## browser refusals"; node drive.mjs auth; echo "rc=$?"
  echo "## curl refusals (status code, body)"
  c() { printf '%-58s ' "$1"; shift; curl -s -o /tmp/mjolnir-rtc-private/c4.body -w '%{http_code} ' "$@"; head -c 120 /tmp/mjolnir-rtc-private/c4.body; echo; }
  c "no token"                                   -X POST -H 'content-type: application/sdp' --data 'v=0' "$EDGE/whip/r1/alice/cam"
  c "malformed bearer"                           -X POST -H 'content-type: application/sdp' -H 'authorization: Bearer abc' --data 'v=0' "$EDGE/whip/r1/alice/cam"
  c "alice token, publish bob/cam"               -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice.tok")" --data 'v=0' "$EDGE/whip/r1/bob/cam"
  c "alice token, publish bare 'alice' (no suffix)" -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice.tok")" --data 'v=0' "$EDGE/whip/r1/alice"
  c "alice token, publish alice/../bob/cam"      -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice.tok")" --data 'v=0' "$EDGE/whip/r1/alice/%2e%2e/bob/cam"
  c "r2 token on /r1/"                           -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice-r2.tok")" --data 'v=0' "$EDGE/whip/r1/alice/cam"
  c "r2 token on /r2/ playing carol/cam (in r1)" -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice-r2.tok")" --data 'v=0' "$EDGE/whep/r2/carol/cam"
  c "forged (other key)"                         -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/forged.tok")" --data 'v=0' "$EDGE/whip/r1/alice/cam"
  c "expired"                                    -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/expired.tok")" --data 'v=0' "$EDGE/whip/r1/alice/cam"
  c "roster with r2 token for r1"                -H "authorization: Bearer $(cat "$P/alice-r2.tok")" "$EDGE/roster/r1"
  c "roster with r2 token for r2 (empty room)"   -H "authorization: Bearer $(cat "$P/alice-r2.tok")" "$EDGE/roster/r2"
  c "valid token, garbage SDP"                   -X POST -H 'content-type: application/sdp' -H "authorization: Bearer $(cat "$P/alice.tok")" --data 'v=0' "$EDGE/whip/r1/alice/cam"
fi
echo "## expiry: alice token ttl 25 s; WHIP alice/cam + WHEP carol/cam, measured from exp"
node drive.mjs expiry alice-ttl carol/cam
kill $PUB 2>/dev/null
echo "## edge log"; grep -E "session accepted|session ended|refused" "$P/edge.log" | cut -c1-260
