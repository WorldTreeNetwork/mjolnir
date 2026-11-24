#!/usr/bin/env bash
# Ordered entrypoint for the complete call-E2EE spike. Local disposable harness only: the relay runs
# in-process from spikes/rust with a QUIC keylog written to $PRIV. Never point any of this at a
# production relay. See README.md for prerequisites (Nix >= 2.24 for @moq/libav, browsers, tshark).
#
#   MOQ=<moq checkout at 4a6f522, with js/libav/dist built and `bun install` done>
#   HARNESS=<dir with package.json {"playwright":"^1.65.1"} and node_modules>
#   ./run-all.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); spikes=$(dirname "$here"); repo=$(cd "$spikes/../../../.." && pwd)
: "${MOQ:?MOQ=path to moq checkout}"; : "${HARNESS:?HARNESS=path to playwright harness dir}"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$repo/native/mjolnir_relay/target}
PRIV=${PRIV:-$(mktemp -d /tmp/mjolnir-e2ee-private.XXXX)}; chmod 700 "$PRIV"; logs=$here/logs; mkdir -p "$logs"
rs() { cargo test --offline --manifest-path "$spikes/rust/Cargo.toml" "$@"; }
wait_file() { for _ in $(seq 1 600); do [ -s "$1" ] && return 0; perl -e 'select(undef,undef,undef,0.5)'; done; return 1; }
redact() { sed -E -i '' 's/eyJ[A-Za-z0-9_.-]+/[TOKEN]/g' "$@" 2>/dev/null || sed -E -i 's/eyJ[A-Za-z0-9_.-]+/[TOKEN]/g' "$@"; }

# 0. Page build + static server (CSP, no-referrer). Copies the harness sources into the moq tree.
spike=$MOQ/js/e2ee/spike; mkdir -p "$spike"
cp "$here"/{page.ts,bridge.ts,validation.ts,validation.test.ts,interop.ts,vite.config.ts} "$spike/"
printf '<!doctype html><meta charset="utf-8"><script type="module" src="./page.ts"></script>\n' > "$spike/index.html"
(cd "$spike" && node ../../../node_modules/vite/bin/vite.js build) > "$logs/vite-build.log" 2>&1
printf '<!doctype html><meta charset="utf-8"><title>control</title><p>history control, no script\n' > "$spike/dist/control.html"
python3 "$here/serve.py" "$spike/dist" > "$PRIV/http.log" 2>&1 & SERVE=$!
cp "$here"/*-drive.mjs "$here/drive.mjs" "$HARNESS/"
trap 'touch "$PRIV/stop"; kill $SERVE 2>/dev/null || true' EXIT

# 1. Unit: upstream JS vectors + layout validation.
(cd "$MOQ/js/e2ee" && bun test src/e2ee.test.ts src/vectors.test.ts src/epoch.test.ts spike/validation.test.ts) > "$logs/js-unit.log" 2>&1

# 2. B1 relabel regression (expected-vulnerable D2 test + label-in-context fix).
rs --test b1_relabel -- --nocapture --test-threads=1 > "$logs/b1-relabel.log" 2>&1

# 3. Rust<->JS interop on the label layout (file exchange, no relay).
I=$PRIV/interop; mkdir -p "$I"
{ E2EE_INTEROP=$I E2EE_PHASE=emit rs --test complete_interop -- --nocapture; (cd "$spike" && bun interop.ts "$I"); E2EE_INTEROP=$I rs --test complete_interop -- --nocapture; } > "$logs/b-interop.log" 2>&1

# 4. Native iroh-live real media; token expiry mid-call.
rs --features native-media --test complete_native -- --nocapture > "$logs/b-native.log" 2>&1
rs --test complete_expiry -- --nocapture --test-threads=1 > "$logs/b-expiry.log" 2>&1

# 5. Cross-direction fixture (native nat publisher + native reader of browser alice) and browser runs.
E2EE_PRIVATE=$PRIV rs --features native-media --test complete_cross -- --ignored --nocapture > "$PRIV/server.log" 2>&1 &
wait_file "$PRIV/admission.txt"
(cd "$HARNESS" && node cross-drive.mjs chromium "$PRIV" 1) > "$logs/b5-cross-chromium.log" 2>&1
(cd "$HARNESS" && node cross-drive.mjs firefox "$PRIV" 0) > "$logs/b5-cross-firefox.log" 2>&1
for b in chromium firefox; do (cd "$HARNESS" && node drive.mjs "$b" "$PRIV") > "$logs/b-$b.log" 2>&1; done

# 6. Relay-key captures: plaintext control, passive encrypted (holders only), token-only (separate).
for m in plaintext encrypted tokenonly; do HARNESS=$HARNESS "$here/capture.sh" "$m" "$PRIV" > "$logs/capture-$m.log" 2>&1; cp "$PRIV/$m-results.json" "$logs/capture-$m-results.json"; done

# 7. Rekey (make-before-break and break-before-make), persistent history, fragment/network leak.
(cd "$HARNESS" && node rekey-drive.mjs "$PRIV") > "$logs/b-rekey.log" 2>&1 || true
for b in chromium firefox; do (cd "$HARNESS" && node history-drive.mjs "$b" "$PRIV") > "$logs/b3c-history-$b.log" 2>&1; done
(cd "$HARNESS" && node fragment-drive.mjs "$PRIV") > "$logs/fragment.log" 2>&1

redact "$logs"/*.log
echo "done; private outputs (keys, pcaps, tokens) in $PRIV — delete when finished"
