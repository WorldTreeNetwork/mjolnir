# Mjolnir — Control Plane
# Works locally (no SSH) or against a remote server via SSH tunnel.
#
# Setup: cp .env.example .env && edit .env (set MJOLNIR_HOST=root@server)
# Usage: just --list

set dotenv-load
set shell := ["bash", "-euo", "pipefail", "-c"]

host := env("MJOLNIR_HOST", "")

# Transport prefix: "ssh host " for remote, "" for local
_t := if host != "" { "ssh " + host + " " } else { "" }
_api := "http://localhost:4000"

default:
    @just --list

[private]
_require-host:
    @if [ -z "{{host}}" ]; then \
        echo "Error: MJOLNIR_HOST not set."; \
        echo "  cp .env.example .env  # then set MJOLNIR_HOST=root@server"; \
        exit 1; \
    fi

# ═══════════════════════════════════════════════════════════════════════
# Local Dev
# ═══════════════════════════════════════════════════════════════════════

compile:
    mix compile

format:
    mix format

format-check:
    mix format --check-formatted

test:
    mix test

# ═══════════════════════════════════════════════════════════════════════
# Chaos tests — run against MJOLNIR_HOST live server
# ═══════════════════════════════════════════════════════════════════════

# Run safe chaos scenarios (skips :destructive: server reboot, full disk, NAT wipe, etc.)
chaos: _require-host
    mix test --only chaos

# Run ALL chaos scenarios including destructive ones — ONLY DO THIS IF YOU MEAN IT.
# Destructive scenarios cause real host downtime (reboot, NAT flush, disk fill, etc.)
chaos-destructive: _require-host
    @echo "WARNING: about to run destructive chaos scenarios against {{host}}"
    @echo "         these cause real host downtime. Ctrl-C now to abort."
    @sleep 5
    mix test --only chaos --include destructive

# Run scenario 1 only (mjolnir restart preserves VMs)
chaos-restart: _require-host
    mix test test/chaos/restart_test.exs --only chaos

# Run scenario 2 only (BEAM SIGKILL preserves VMs)
chaos-sigkill: _require-host
    mix test test/chaos/sigkill_beam_test.exs --only chaos

# Run scenario 4 only (single CH SIGKILL, Monitor auto-recovers)
chaos-ch-sigkill: _require-host
    mix test test/chaos/ch_sigkill_test.exs --only chaos

# Run scenario 3 only (server reboot — DESTRUCTIVE, ~60s downtime)
chaos-reboot: _require-host
    @echo "WARNING: server reboot scenario — host will be offline ~60s. Ctrl-C to abort."
    @sleep 5
    mix test test/chaos/reboot_test.exs --only chaos --include destructive

iex:
    iex -S mix

deps:
    mix deps.get

clean:
    mix clean

build-client:
    ./scripts/build-client.sh

# Build the forked Forgejo runner
build-runner:
    cd native/forgejo-runner && go build ./...

# ═══════════════════════════════════════════════════════════════════════
# Deploy
# ═══════════════════════════════════════════════════════════════════════

# Deploy Elixir code + guest agent (with Iroh P2P)
deploy: _require-host
    ./scripts/deploy.sh {{host}} --agent

# Deploy code + agent + rebuild initramfs boot image
deploy-boot: _require-host
    ./scripts/deploy.sh {{host}} --agent
    ssh {{host}} "cd /opt/mjolnir/native && \
        export PATH=\"/root/.cargo/bin:/root/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:\$PATH\" && \
        eval \"\$(\$HOME/.local/bin/mise activate bash 2>/dev/null || true)\" && \
        cargo zigbuild --release \
            --target x86_64-unknown-linux-musl \
            -p mjolnir-guest-agent --bin mjolnir-boot-agent --no-default-features --features boot"
    ssh {{host}} "cd /opt/mjolnir && bash scripts/build-initramfs.sh"
    ssh {{host}} "mkdir -p /var/lib/mjolnir/boot && \
        cp /opt/mjolnir/boot-image/initramfs.img /var/lib/mjolnir/boot/initramfs.img && \
        chmod 644 /var/lib/mjolnir/boot/initramfs.img"

# Rebuild base rootfs image on server (distro: ubuntu-24.04, arch)
deploy-rootfs distro="ubuntu-24.04": _require-host
    ssh {{host}} "cd /opt/mjolnir && \
        AGENT_BIN=native/target/x86_64-unknown-linux-musl/release/mjolnir-agent \
        bash scripts/build-rootfs-{{distro}}.sh /var/lib/mjolnir/btrfs/@base/{{distro}}"

# Build CI base image on the server (@base/ci-ubuntu-24.04)
build-ci-image: _require-host
    ssh {{host}} "cd /opt/mjolnir && sudo bash scripts/build-ci-image.sh /var/lib/mjolnir/btrfs/@base/ci-ubuntu-24.04"

# Deploy code + build Forgejo runner with Mjolnir VM backend
deploy-runner: _require-host
    ./scripts/deploy.sh {{host}} --runner

# Deploy code + rebuild web gateway binary
deploy-gateway: _require-host
    ./scripts/deploy.sh {{host}} --gateway

# Bootstrap a fresh server (rsync code + run bootstrap script)
bootstrap: _require-host
    rsync -avz --delete --filter=':- .gitignore' --exclude='.git' . {{host}}:/opt/mjolnir/
    ssh {{host}} 'export PATH="$HOME/.local/bin:$PATH" && \
        command -v mise >/dev/null 2>&1 && mise trust /opt/mjolnir/.mise.toml 2>/dev/null; \
        cd /opt/mjolnir && SKIP_FIRECRACKER=1 USE_LOOPBACK=1 ./scripts/bootstrap-host-ubuntu.sh'

# ═══════════════════════════════════════════════════════════════════════
# IdentiKey Sites — publish & inspect static-content snapshots
# ═══════════════════════════════════════════════════════════════════════

# Publish a directory as a public-mode IdentiKey site.
# Example: just sites-publish ./blog abc123 blog
sites-publish dir fp name sequence="1":
    mix mjolnir.sites.publish {{dir}} \
        --identikey-fp {{fp}} \
        --site {{name}} \
        --base-url {{_api}} \
        --sequence {{sequence}}

# Add a custom-domain alias for a site.
# Example: just sites-alias-add blog.duke.io abc123 blog ./identity.json
sites-alias-add fqdn fp site keypair_file sequence="1":
    mix mjolnir.sites.alias add {{fqdn}} \
        --identikey-fp {{fp}} \
        --site {{site}} \
        --keypair-file {{keypair_file}} \
        --base-url {{_api}} \
        --sequence {{sequence}}

# Remove a custom-domain alias for a site (signed tombstone).
sites-alias-remove fqdn fp site keypair_file sequence="9999999999":
    mix mjolnir.sites.alias remove {{fqdn}} \
        --identikey-fp {{fp}} \
        --site {{site}} \
        --keypair-file {{keypair_file}} \
        --base-url {{_api}} \
        --sequence {{sequence}}

# Fetch the current HEAD record for a site
sites-head fp name:
    {{_t}}curl -s --fail-with-body {{_api}}/api/sites/{{fp}}/{{name}}/head

# Fetch a manifest envelope by snapshot hash
sites-manifest hash:
    {{_t}}curl -s --fail-with-body {{_api}}/api/sites/manifests/{{hash}}

# Fetch an OpenTimestamps receipt by snapshot hash
sites-ots hash:
    {{_t}}curl -s --fail-with-body --output - {{_api}}/api/sites/manifests/{{hash}}/ots

# Fetch a served file from a site (debug endpoint)
# Example: just sites-get abc123 blog index.html
sites-get fp name path:
    {{_t}}curl -s --fail-with-body {{_api}}/api/sites/{{fp}}/{{name}}/files/{{path}}

# ═══════════════════════════════════════════════════════════════════════
# Server Management
# ═══════════════════════════════════════════════════════════════════════

# Open an interactive SSH session
ssh: _require-host
    ssh {{host}}

# Show mjolnir service status
status: _require-host
    ssh {{host}} "systemctl status mjolnir --no-pager"

# Follow mjolnir service logs (live)
logs: _require-host
    ssh -t {{host}} "journalctl -u mjolnir -f"

# Show recent mjolnir service logs
logs-recent n="100": _require-host
    ssh {{host}} "journalctl -u mjolnir -n {{n}} --no-pager"

# Restart mjolnir service
restart: _require-host
    ssh {{host}} "systemctl restart mjolnir"

# Attach to remote IEx shell
remote-shell: _require-host
    ssh -t {{host}} "/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote"

# Show TAP interface + routes for a VM
debug-vm id: _require-host
    ssh {{host}} "echo '=== TAP Interface ===' && \
        ip link show mj-{{id}} 2>/dev/null || echo 'TAP not found: mj-{{id}}' && \
        echo '' && echo '=== Routes ===' && \
        ip route | grep mj-{{id}} || echo 'No routes for mj-{{id}}'"

# Remove orphaned TAP interfaces
cleanup-taps: _require-host
    ssh {{host}} 'for tap in $(ip link show | grep -oP "mj-\w+" | sort -u); do \
        echo "Removing $tap"; ip link del "$tap" 2>/dev/null || true; \
    done && echo "Done"'

# Show IP forwarding, NAT rules, TAP interfaces
server-networking: _require-host
    ssh {{host}} "echo '=== IP Forwarding ===' && cat /proc/sys/net/ipv4/ip_forward && \
        echo '' && echo '=== NAT Rules ===' && \
        iptables -t nat -L POSTROUTING -v 2>/dev/null | head -5 || echo '(none)' && \
        echo '' && echo '=== TAP Interfaces ===' && \
        ip link show | grep mj- || echo '(none)'"

# Show gateway service status
gateway-status: _require-host
    ssh {{host}} "systemctl status mjolnir-gateway --no-pager"

# Follow gateway service logs (live)
gateway-logs: _require-host
    ssh -t {{host}} "journalctl -u mjolnir-gateway -f"

# Show recent gateway service logs
gateway-logs-recent n="100": _require-host
    ssh {{host}} "journalctl -u mjolnir-gateway -n {{n}} --no-pager"

# Restart gateway service
gateway-restart: _require-host
    ssh {{host}} "systemctl restart mjolnir-gateway"

# ═══════════════════════════════════════════════════════════════════════
# Forge (host config reconciler)  — see docs/plans/host-reconcile.md
# ═══════════════════════════════════════════════════════════════════════

# Forge: list managed hosts (running + declared)
forge-hosts:
    {{_t}}curl -s --fail-with-body {{_api}}/api/forge/hosts | jq .

# Forge: start a Host worker (defaults: transport=local, auto_apply=false)
forge-host-add host_id transport="local":
    #!/usr/bin/env bash
    body=$(jq -n --arg h "{{host_id}}" --arg t "{{transport}}" '{host:$h, transport:$t, auto_apply:false}')
    if [ -n "{{host}}" ]; then
        echo "$body" | ssh {{host}} "curl -s --fail-with-body -X POST {{_api}}/api/forge/hosts -H 'Content-Type: application/json' -d @-" | jq .
    else
        echo "$body" | curl -s --fail-with-body -X POST {{_api}}/api/forge/hosts -H 'Content-Type: application/json' -d @-  | jq .
    fi

# Forge: re-observe + diff for a host (read-only; no host changes)
forge-plan host_id="self":
    {{_t}}curl -s --fail-with-body "{{_api}}/api/forge/plan?host={{host_id}}" | jq .

# Forge: apply safe actions (:new, :drifted, :missing, :prune) for a host
forge-apply host_id="self":
    #!/usr/bin/env bash
    body=$(jq -n --arg h "{{host_id}}" '{host:$h, keys:"all_safe"}')
    if [ -n "{{host}}" ]; then
        echo "$body" | ssh {{host}} "curl -s --fail-with-body -X POST {{_api}}/api/forge/apply -H 'Content-Type: application/json' -d @-" | jq .
    else
        echo "$body" | curl -s --fail-with-body -X POST {{_api}}/api/forge/apply -H 'Content-Type: application/json' -d @- | jq .
    fi

# Forge: list Store records (optionally filtered by host/kind/status)
forge-state host_id="" kind="" status_filter="":
    {{_t}}curl -s --fail-with-body "{{_api}}/api/forge/state?host={{host_id}}&kind={{kind}}&status={{status_filter}}" | jq .

# Forge: recent reconciliation events (audit feed); since="" shows last `limit`
forge-events since="" limit="100":
    {{_t}}curl -s --fail-with-body "{{_api}}/api/forge/events?since={{since}}&limit={{limit}}" | jq .

# Forge: follow the live event stream (SSE; Ctrl-C to stop). Resume with since=<id>
forge-events-tail since="":
    {{_t}}curl -sN "{{_api}}/api/forge/events/stream?since={{since}}"

# ═══════════════════════════════════════════════════════════════════════
# MCP Smoke Tests
# ═══════════════════════════════════════════════════════════════════════

# MCP: Initialize handshake
mcp-init:
    {{_t}}curl -s -X POST {{_api}}/mcp -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.1"}}}' | jq .

# MCP: List all registered tools
mcp-tools:
    {{_t}}curl -s -X POST {{_api}}/mcp -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | jq '.result.tools[] | .name'

# MCP: Call list_vms tool
mcp-list-vms:
    {{_t}}curl -s -X POST {{_api}}/mcp -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_vms","arguments":{}}}' | jq .

# MCP: Run full smoke test (init + tools + list_vms)
mcp-smoke:
    #!/usr/bin/env bash
    _curl() { {{_t}}curl -s -X POST {{_api}}/mcp -H 'Content-Type: application/json' -d "$1"; }
    echo "=== MCP Initialize ==="
    INIT=$(_curl '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.1"}}}')
    if echo "$INIT" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
        echo "PASS: $(echo "$INIT" | jq -r '.result.serverInfo.name') v$(echo "$INIT" | jq -r '.result.serverInfo.version')"
    else
        echo "FAIL: $INIT"; exit 1
    fi
    echo ""
    echo "=== MCP Tools List ==="
    TOOLS=$(_curl '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    COUNT=$(echo "$TOOLS" | jq '.result.tools | length')
    echo "PASS: $COUNT tools registered"
    echo ""
    echo "=== MCP tools/call list_vms ==="
    VMS=$(_curl '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_vms","arguments":{}}}')
    if echo "$VMS" | jq -e '.result.content' > /dev/null 2>&1; then
        echo "PASS: $(echo "$VMS" | jq -r '.result.content[0].text')"
    else
        echo "FAIL: $VMS"; exit 1
    fi
    echo ""
    echo "=== All MCP smoke tests passed ==="
