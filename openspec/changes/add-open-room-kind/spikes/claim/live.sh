#!/usr/bin/env bash
# Claim route, live: two harness relays trusting the same dummy key, one deciding with route (b), one with the
# production decider. Native WebTransport clients from native/mjolnir_relay/examples/wt-session.
#   claim/live.sh <private-dir>    (needs: mint_fixtures.exs output in <private-dir>, built spike + wt-session)
set -u
P=$1; here=$(cd "$(dirname "$0")/.." && pwd); repo=$(cd "$here/../../../.." && pwd)
B=${B:-$repo/native/mjolnir_relay/target/debug}
rm -f "$P/stop" "$P"/relay-claim.txt "$P"/relay-prod.txt
"$B/open-room-kind-spike" relay-claim "$P" claim > "$P/relay-claim.log" 2>&1 &
"$B/open-room-kind-spike" relay-claim "$P" prod > "$P/relay-prod.log" 2>&1 &
for _ in $(seq 1 60); do [ -f "$P/relay-claim.txt" ] && [ -f "$P/relay-prod.txt" ] && break; sleep 0.5; done
C=$(cat "$P/relay-claim.txt"); D=$(cat "$P/relay-prod.txt")
j() { python3 -c "import json,sys;d=json.load(open('$P/fixtures.json'));print(eval(sys.argv[1]))" "$1"; }
OPEN=$(j "d['live']['open']"); PROT=$(j "d['live']['protected']"); NONE=$(j "d['live']['none']"); ROOT=$(j "d['root']")
WT=$B/examples/wt-session
echo "# claim route, live harness relays (WebTransport), $(date -u +%FT%TZ); tokens minted by claim/mint_fixtures.exs, host clock, life 300 s"
echo "## route (b) relay: kind=open publisher alice, kind=open reader"
( "$WT" publish "https://$C/$ROOT?jwt=$OPEN" alice 6 ) & PUB=$!
sleep 1.5
"$WT" read "https://$C/$ROOT?jwt=$OPEN" alice 5 2>&1 | grep -E "^received|Error"
wait $PUB
echo "## route (b) relay: kind=protected session, no-kind session (today's token shape)"
"$WT" hold "https://$C/$ROOT?jwt=$PROT" 1 2>&1 | head -1
"$WT" hold "https://$C/$ROOT?jwt=$NONE" 1 2>&1 | head -1
echo "## production decider (spawn_web_decider, the code running on 45.76.77.97): kind=open, kind=protected, no-kind"
"$WT" refuse "https://$D/$ROOT?jwt=$OPEN" 2>&1 | head -1
"$WT" refuse "https://$D/$ROOT?jwt=$PROT" 2>&1 | head -1
"$WT" hold "https://$D/$ROOT?jwt=$NONE" 1 2>&1 | head -1
echo "## route (b) relay decisions"
grep -E "admitted|refused" "$P/relay-claim.log"
touch "$P/stop"
