# Executed on Morphie/archbox in a fresh /tmp/mjolnir-i6-run.
# Prepare as complete/README.md; use a fresh private directory with no stop/admission files.
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/share/mise/installs/node/25.9.0/bin:$PATH"
cd /tmp/mjolnir-i6-run
cp -f openspec/changes/add-call-e2ee/spikes/complete/rekey-drive.mjs harness/rekey-drive.mjs
relay_bin=$(find target/debug/deps -maxdepth 1 -type f -executable -name 'complete_server-*' -print -quit)
test -n "$relay_bin"
export E2EE_PRIVATE=$PWD/private
"$relay_bin" --ignored --nocapture > private/server.log 2>&1 & relay_pid=$!
python3 openspec/changes/add-call-e2ee/spikes/complete/serve.py www > private/http.log 2>&1 & http_pid=$!
trap 'touch "$E2EE_PRIVATE/stop"; kill "$http_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do test -s private/admission.txt && break; sleep .1; done
test -s private/admission.txt
# No compilation or media build during this interval.
{
 date -u
 uname -srm
 getconf _NPROCESSORS_ONLN
 uptime
 vmstat 1 2 | tail -3
 cd harness
 set +e
 timeout 120 node rekey-drive.mjs ../private
 rc=$?
 set -e
 echo "driver_exit=$rc"
 uptime
 vmstat 1 2 | tail -3
 exit "$rc"
} > /tmp/mjolnir-i6-run/private/i6-morphie.log 2>&1
