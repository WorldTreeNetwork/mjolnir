#!/usr/bin/env bash
# Usage: capture.sh <mode> <private-dir>   (mode: plaintext | encrypted | tokenonly)
# Runs the browser capture, then decrypts the QUIC with the HARNESS relay's keylog and reassembles STREAM bytes.
set -euo pipefail
mode=$1; dir=$2; here=$(cd "$(dirname "$0")" && pwd)
port=$(head -1 "$dir/admission.txt" | cut -d: -f2)
node "${HARNESS:?set HARNESS to the dir holding node_modules/playwright}/capture-drive.mjs" "$mode" "$dir" | tee "$dir/$mode-drive.json"
tshark -r "$dir/$mode.pcapng" -o "tls.keylog_file:$dir/relay.keys" -d "udp.port==$port,quic" -T pdml 2>"$dir/$mode-pdml.err" \
  | python3 -I "$here/extract.py" "$dir" "$mode" --stdin
