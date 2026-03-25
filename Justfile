# Mjolnir — Local Control Plane
# Sit on your Mac, operate everything: local dev runs locally,
# VM operations go through the HTTP API via SSH, server management via SSH.
#
# Setup: cp .env.example .env && edit .env
# Usage: just --list

set dotenv-load
set shell := ["bash", "-euo", "pipefail", "-c"]

host := env("MJOLNIR_HOST", "")

# Default recipe — show available commands
default:
    @just --list

# ─── Guard ────────────────────────────────────────────────────────────

[private]
_require-host:
    @if [ -z "{{host}}" ]; then \
        echo "Error: No host configured."; \
        echo ""; \
        echo "  cp .env.example .env && edit .env"; \
        echo "  OR: export MJOLNIR_HOST=root@1.2.3.4"; \
        echo "  OR: just host=root@1.2.3.4 <recipe>"; \
        exit 1; \
    fi

# ═══════════════════════════════════════════════════════════════════════
# Local Dev (no SSH needed)
# ═══════════════════════════════════════════════════════════════════════

# Compile the project
compile:
    mix compile

# Format all Elixir code
format:
    mix format

# Check formatting without modifying
format-check:
    mix format --check-formatted

# Run unit tests
test:
    mix test

# Start IEx with Mjolnir loaded
iex:
    iex -S mix

# Fetch dependencies
deps:
    mix deps.get

# Clean build artifacts
clean:
    mix clean

# Build the TypeScript client
build-client:
    ./scripts/build-client.sh

# ═══════════════════════════════════════════════════════════════════════
# Deploy
# ═══════════════════════════════════════════════════════════════════════

# Deploy code to server (rsync + build release + restart)
deploy: _require-host
    ./scripts/deploy.sh {{host}}

# Deploy code + rebuild guest agent
deploy-full: _require-host
    ./scripts/deploy.sh {{host}} --agent

# Deploy code + rebuild rootfs
deploy-rootfs: _require-host
    ./scripts/deploy.sh {{host}} --rootfs

# Deploy code + rebuild gateway binary
deploy-gateway: _require-host
    ./scripts/deploy.sh {{host}} --gateway

# --- Boot image pipeline ---

# Cross-compile the boot agent (musl static binary) on server
build-boot-agent: _require-host
    ssh {{host}} "cd /opt/mjolnir && \
        export PATH=\"/root/.cargo/bin:/root/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:\$PATH\" && \
        eval \"\$(\$HOME/.local/bin/mise activate bash 2>/dev/null || true)\" && \
        cargo build --release \
            --target x86_64-unknown-linux-musl \
            -p mjolnir-guest-agent --bin mjolnir-boot-agent --no-default-features --features boot"

# Build the initramfs cpio archive on server (requires build-boot-agent)
build-initramfs: build-boot-agent
    ssh {{host}} "cd /opt/mjolnir && bash scripts/build-initramfs.sh"

# Deploy initramfs + boot agent to /var/lib/mjolnir/boot/ on server
deploy-boot: _require-host
    ssh {{host}} "mkdir -p /var/lib/mjolnir/boot && \
        cp /opt/mjolnir/boot-image/initramfs.img /var/lib/mjolnir/boot/initramfs.img && \
        cp /opt/mjolnir/native/target/x86_64-unknown-linux-musl/release/mjolnir-boot-agent \
            /var/lib/mjolnir/boot/mjolnir-boot-agent && \
        chmod 644 /var/lib/mjolnir/boot/initramfs.img && \
        chmod 755 /var/lib/mjolnir/boot/mjolnir-boot-agent"
    @echo "Deployed. To activate initramfs boot:"
    @echo "  Set MJOLNIR_INITRAMFS_PATH=/var/lib/mjolnir/boot/initramfs.img"
    @echo "  Then: just restart"

# ═══════════════════════════════════════════════════════════════════════
# VM Operations (SSH + curl localhost:4000)
# ═══════════════════════════════════════════════════════════════════════

# Check API health
health: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/health" | jq .

# Spawn a new VM
vm-spawn: _require-host
    ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms -H 'Content-Type: application/json' -d '{}'" | jq .

# Spawn a VM from a snapshot
vm-spawn-from snapshot: _require-host
    jq -n --arg s '{{snapshot}}' '{snapshot: $s}' | \
        ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms -H 'Content-Type: application/json' -d @-" | jq .

# List all running VMs
vm-list: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/vms" | jq .

# Get VM details
vm-info id: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/vms/{{id}}" | jq .

# Execute a command in a VM
vm-exec id cmd: _require-host
    jq -n --arg cmd '{{cmd}}' '{command: $cmd}' | \
        ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms/{{id}}/exec -H 'Content-Type: application/json' -d @-" | jq .

# Stop a VM
vm-stop id: _require-host
    ssh {{host}} "curl -s --fail-with-body -X DELETE http://localhost:4000/api/vms/{{id}}" | jq .

# Stop all running VMs
vm-stop-all: _require-host
    ssh {{host}} 'for id in $(curl -s http://localhost:4000/api/vms | jq -r ".vms[].id"); do echo "Stopping $id..."; curl -s -X DELETE "http://localhost:4000/api/vms/$id" | jq .; done'

# Get the web gateway URL for a VM
vm-url id: _require-host
    @ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/vms/{{id}}" | jq -r '.web_url // empty'

# Get connection ticket for a VM
vm-ticket id: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/vms/{{id}}/ticket" | jq .

# Await PTY readiness for a VM
vm-await-pty id: _require-host
    ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms/{{id}}/await-pty -H 'Content-Type: application/json' -d '{}'" | jq .

# Send a message to a VM (payload is JSON, e.g. '{"key":"val"}')
vm-message id payload: _require-host
    jq -n --argjson p '{{payload}}' '{payload: $p}' | \
        ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms/{{id}}/messages -H 'Content-Type: application/json' -d @-" | jq .

# ═══════════════════════════════════════════════════════════════════════
# Snapshots
# ═══════════════════════════════════════════════════════════════════════

# Create a snapshot of a VM
snap-create id name: _require-host
    jq -n --arg n '{{name}}' '{name: $n}' | \
        ssh {{host}} "curl -s --fail-with-body -X POST http://localhost:4000/api/vms/{{id}}/snapshots -H 'Content-Type: application/json' -d @-" | jq .

# List all snapshots
snap-list: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/snapshots" | jq .

# Get snapshot details
snap-info name: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/snapshots/{{name}}" | jq .

# Delete a snapshot
snap-delete name: _require-host
    ssh {{host}} "curl -s --fail-with-body -X DELETE http://localhost:4000/api/snapshots/{{name}}" | jq .

# List dormant VMs
dormant: _require-host
    ssh {{host}} "curl -s --fail-with-body http://localhost:4000/api/dormant" | jq .

# ═══════════════════════════════════════════════════════════════════════
# Server Management (SSH)
# ═══════════════════════════════════════════════════════════════════════

# SSH into the server
ssh: _require-host
    ssh {{host}}

# Show mjolnir service status
status: _require-host
    ssh {{host}} "systemctl status mjolnir --no-pager"

# Follow mjolnir service logs
logs: _require-host
    ssh -t {{host}} "journalctl -u mjolnir -f"

# Show recent mjolnir service logs
logs-recent n="100": _require-host
    ssh {{host}} "journalctl -u mjolnir -n {{n}} --no-pager"

# Restart mjolnir service
restart: _require-host
    ssh {{host}} "systemctl restart mjolnir"

# Stop mjolnir service
stop-service: _require-host
    ssh {{host}} "systemctl stop mjolnir"

# Start mjolnir service
start-service: _require-host
    ssh {{host}} "systemctl start mjolnir"

# Attach to remote IEx shell
remote-shell: _require-host
    ssh -t {{host}} "/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote"

# Debug a VM's network config (TAP + routes)
debug-vm id: _require-host
    ssh {{host}} "echo '=== TAP Interface ===' && ip link show mj-{{id}} 2>/dev/null || echo 'TAP not found: mj-{{id}}' && echo '' && echo '=== Routes ===' && ip route | grep mj-{{id}} || echo 'No routes for mj-{{id}}'"

# Clean up orphaned TAP interfaces
cleanup-taps: _require-host
    ssh {{host}} 'for tap in $(ip link show | grep -oP "mj-\w+" | sort -u); do echo "Removing $tap"; ip link del "$tap" 2>/dev/null || true; done && echo "Done"'

# Show server networking status (IP forwarding, NAT, TAPs)
server-networking: _require-host
    ssh {{host}} "echo '=== IP Forwarding ===' && cat /proc/sys/net/ipv4/ip_forward && echo '' && echo '=== NAT Rules ===' && iptables -t nat -L POSTROUTING -v 2>/dev/null | head -5 || echo '(none)' && echo '' && echo '=== TAP Interfaces ===' && ip link show | grep mj- || echo '(none)'"

# Show gateway service status
gateway-status: _require-host
    ssh {{host}} "systemctl status mjolnir-gateway --no-pager"

# Follow gateway service logs
gateway-logs: _require-host
    ssh -t {{host}} "journalctl -u mjolnir-gateway -f"

# Show recent gateway service logs
gateway-logs-recent n="100": _require-host
    ssh {{host}} "journalctl -u mjolnir-gateway -n {{n}} --no-pager"

# Restart gateway service
gateway-restart: _require-host
    ssh {{host}} "systemctl restart mjolnir-gateway"

# Build guest agent on the server
server-build-agent: _require-host
    ssh {{host}} "cd /opt/mjolnir && ./scripts/build-guest-agent.sh"

# Build rootfs on the server
server-build-rootfs: _require-host
    ssh {{host}} "cd /opt/mjolnir && AGENT_BIN=native/target/x86_64-unknown-linux-musl/release/mjolnir-agent ./scripts/build-rootfs.sh /var/lib/mjolnir/btrfs/@base/ubuntu-24.04"

# Bootstrap a fresh server (rsync code, trust mise, run bootstrap)
bootstrap: _require-host
    rsync -avz --delete --filter=':- .gitignore' --exclude='.git' . {{host}}:/opt/mjolnir/ && \
        ssh {{host}} 'export PATH="$HOME/.local/bin:$PATH" && command -v mise >/dev/null 2>&1 && mise trust /opt/mjolnir/.mise.toml 2>/dev/null; cd /opt/mjolnir && SKIP_FIRECRACKER=1 USE_LOOPBACK=1 ./scripts/bootstrap-host.sh'

# ═══════════════════════════════════════════════════════════════════════
# MCP Smoke Tests (JSON-RPC over HTTP)
# ═══════════════════════════════════════════════════════════════════════

# MCP: Initialize handshake
mcp-init: _require-host
    ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke-test\",\"version\":\"0.1\"}}}"' | jq .

# MCP: List all available tools
mcp-tools: _require-host
    ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"' | jq '.result.tools[] | .name'

# MCP: Call list_vms tool
mcp-list-vms: _require-host
    ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_vms\",\"arguments\":{}}}"' | jq .

# MCP: Run full smoke test (init + tools + list_vms)
mcp-smoke: _require-host
    #!/usr/bin/env bash
    echo "=== MCP Initialize ==="
    INIT=$(ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke-test\",\"version\":\"0.1\"}}}"')
    if echo "$INIT" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
        echo "PASS: $(echo "$INIT" | jq -r '.result.serverInfo.name') v$(echo "$INIT" | jq -r '.result.serverInfo.version')"
    else
        echo "FAIL: $INIT"; exit 1
    fi
    echo ""
    echo "=== MCP Tools List ==="
    TOOLS=$(ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"')
    COUNT=$(echo "$TOOLS" | jq '.result.tools | length')
    if [ "$COUNT" = "13" ]; then
        echo "PASS: $COUNT tools registered"
    else
        echo "FAIL: expected 13 tools, got $COUNT"; exit 1
    fi
    echo ""
    echo "=== MCP tools/call list_vms ==="
    VMS=$(ssh {{host}} 'curl -s -X POST http://localhost:4000/mcp -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_vms\",\"arguments\":{}}}"')
    if echo "$VMS" | jq -e '.result.content' > /dev/null 2>&1; then
        echo "PASS: $(echo "$VMS" | jq -r '.result.content[0].text')"
    else
        echo "FAIL: $VMS"; exit 1
    fi
    echo ""
    echo "=== All MCP smoke tests passed ==="
