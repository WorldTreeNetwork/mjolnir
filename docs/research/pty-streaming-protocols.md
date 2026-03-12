# PTY Streaming and Remote Terminal Protocols: Research Analysis

## Context

Mjolnir is a microVM platform with two connection paths to VM shells:

1. **Iroh QUIC direct connect** (`mjolnir iroh connect <ticket>`) -- P2P NAT-traversing QUIC connection using the `mjolnir-shell/1` ALPN, carrying a custom binary frame protocol (Data/Resize/Exit/Hello).
2. **WebSocket PTY** (`mjolnir connect <vm_id>`) -- authenticated WebSocket through the Mjolnir API server, carrying raw binary PTY bytes (WS Binary frames) with JSON resize messages (WS Text frames).

Both paths terminate at the guest agent's `PtySession`, which uses `openpty(2)` + `fork(2)` to spawn `/bin/bash` with a real PTY pair. The client sets the local terminal to raw mode and does bidirectional byte copying.

This document analyzes how to make these connections integrate with iTerm2's tmux control mode, terminal multiplexers, and AI agent orchestration.

---

## 1. Current Architecture: How Mjolnir PTY Streaming Works

### 1.1 The Iroh Shell Protocol (`mjolnir-shell/1`)

**Wire format** (defined in `mjolnir_protocol/src/lib.rs`):

```
[1 byte: message type] [4 bytes: payload length (BE)] [N bytes: payload]
```

| Type | Byte | Payload |
|------|------|---------|
| Data | 0x01 | Raw terminal bytes (stdin/stdout) |
| Resize | 0x02 | rows(u16 BE) + cols(u16 BE) |
| Exit | 0x03 | exit_code(i32 BE) |
| Hello | 0x04 | rows(u16 BE) + cols(u16 BE) + version(u16 BE) |

**Connection lifecycle:**
1. Client binds an Iroh endpoint, connects with `SHELL_ALPN`
2. Opens a bidirectional QUIC stream
3. Sends `Hello` frame with terminal dimensions and protocol version
4. Guest agent spawns `PtySession::spawn("/bin/bash", cols, rows)`
5. Bidirectional copy: client stdin -> Data frames -> PTY stdin; PTY stdout -> Data frames -> client stdout
6. SIGWINCH on client triggers `Resize` frame -> `ioctl(TIOCSWINSZ)` + `SIGWINCH` to child
7. Shell exit -> `Exit` frame with code

**Key properties:**
- Transport: QUIC (UDP), NAT-traversing via Iroh relay servers
- Encryption: QUIC TLS 1.3 with Iroh node identity keys
- Framing: length-prefixed binary, max payload 16MB
- Latency: comparable to direct UDP; relay adds one hop when hole-punching fails

### 1.2 The WebSocket PTY Protocol

**Wire format** (defined in `mjolnir_client/src/connect.rs`):
- **WS Binary frames**: raw PTY bytes (both directions)
- **WS Text frames**: JSON control messages (`{"type": "resize", "rows": N, "cols": N}`)

**Connection lifecycle:**
1. Client opens `wss://<api>/api/vms/<id>/pty` with Bearer auth
2. Server-side (Elixir) opens a vsock channel to the guest agent, sends `pty_open`
3. Guest agent allocates a PTY channel (u8 ID), spawns bash, returns `pty_opened`
4. Bidirectional: WS Binary -> vsock channel -> PTY stdin; PTY stdout -> vsock channel -> WS Binary
5. SIGWINCH -> JSON resize message -> `pty_resize` vsock command

**Key properties:**
- Transport: TCP + TLS (WebSocket)
- Auth: Bearer token
- Multiplexed: vsock uses channel IDs (u8, 1-255) allowing up to 255 concurrent PTY sessions per VM
- The Elixir host acts as a proxy between the WebSocket and vsock

### 1.3 Comparison: xterm.js vs Raw PTY

Mjolnir's approach is a **raw PTY byte stream**, not an xterm.js-style protocol. The distinction matters:

| | xterm.js style | Mjolnir style |
|---|---|---|
| Terminal emulation | In-browser (JavaScript) | Native terminal (iTerm2, etc.) |
| Rendering | Canvas/DOM | Host terminal handles ANSI |
| Transport | WebSocket to relay server | WebSocket or QUIC to VM |
| Resize | Client sends new dimensions | Client sends new dimensions |
| Input | Keyboard events -> bytes | Raw terminal bytes |
| Integration | Browser only | Any terminal, tmux, script |

Mjolnir's raw approach is architecturally better for multiplexer integration because the data is already just bytes -- no terminal emulation layer sits in between.

---

## 2. tmux Control Mode (`tmux -CC`)

### 2.1 What Control Mode Is

tmux control mode (`-CC`) is a machine-readable protocol for controlling tmux. Instead of rendering terminal output inside a curses-based UI, tmux emits structured text commands on stdout and accepts commands on stdin. iTerm2 uses this to provide native tmux integration -- each tmux window becomes an iTerm2 tab, each pane becomes an iTerm2 split.

### 2.2 The Protocol

When you run `tmux -CC`, tmux communicates using a line-oriented text protocol:

**Output (tmux -> client):**
```
%begin <timestamp> <command-number> <flags>
<output lines>
%end <timestamp> <command-number> <flags>

%output %<pane-id> <data>

%window-add @<window-id>
%window-close @<window-id>
%window-renamed @<window-id> <new-name>

%session-changed $<session-id> <session-name>
%session-renamed <new-name>

%layout-change @<window-id> <layout-string>

%pane-mode-changed %<pane-id>

%exit [reason]
```

**Input (client -> tmux):**
Any valid tmux command, one per line:
```
new-window -n "my-vm"
send-keys -t %3 "ls -la" Enter
split-window -h
resize-pane -t %3 -x 80 -y 24
capture-pane -t %3 -p
```

**Key protocol details:**
- `%output` lines carry PTY output from panes, with the data being the raw terminal bytes (potentially escaped for the control channel)
- `%begin`/`%end` blocks wrap command responses
- Pane IDs are `%N` (e.g., `%0`, `%1`), window IDs are `@N`, session IDs are `$N`
- The control client sends tmux commands as plain text lines
- Data in `%output` is octal-escaped for bytes outside printable ASCII

### 2.3 How iTerm2 Uses It

iTerm2's tmux integration works as follows:

1. iTerm2 spawns `tmux -CC` (or `tmux -CC attach`)
2. iTerm2 parses the control protocol output
3. Each tmux window becomes a native iTerm2 tab
4. Each tmux pane becomes a native iTerm2 split pane
5. iTerm2 handles rendering (using its own terminal emulator)
6. User input goes through iTerm2 -> `send-keys` command -> tmux -> PTY
7. PTY output comes back via `%output` -> iTerm2 renders it

**Creating windows/panes programmatically via control mode:**
```
# Create a new window
new-window -t mysession -n "vm-abc123" "mjolnir connect abc123"

# Split the current window
split-window -h "mjolnir connect def456"

# Send keystrokes to a pane
send-keys -t %5 "echo hello" Enter

# Capture pane content (for reading)
capture-pane -t %5 -p -S -100
```

### 2.4 Integration Strategy for Mjolnir

There are several approaches to making `mjolnir connect` work beautifully with tmux -CC:

#### Option A: Run `mjolnir connect` Inside tmux Panes (Simple)

The simplest approach: `mjolnir connect` already works as a raw PTY client. Just run it inside a tmux pane.

```bash
# From a tmux control mode session:
tmux new-window -n "vm-abc" "mjolnir connect abc123"
```

This works today. iTerm2 renders it as a native tab. The `mjolnir` process handles raw mode and SIGWINCH.

**Trade-off:** Each VM connection is a separate process. The `mjolnir` binary must be available on the machine running tmux. There is no way to "hand off" an existing connection to a new pane.

#### Option B: tmux `pipe-pane` for Logging/Monitoring

tmux's `pipe-pane` command copies pane output to a process:

```bash
tmux pipe-pane -t %3 -o "cat >> /tmp/vm-abc.log"
```

This is useful for capturing VM session output for AI agent consumption but does not provide input.

#### Option C: Native tmux Protocol Bridge (Advanced)

Build a `mjolnir tmux-bridge` command that:
1. Connects to tmux's control mode socket
2. Creates windows/panes for each VM
3. Bridges the Mjolnir protocol frames directly to tmux pane I/O

This would require implementing a tmux client library that speaks the control protocol. The benefit is zero-overhead integration and the ability to manage VM sessions as tmux primitives.

**Implementation sketch:**
```
mjolnir tmux-bridge --session mjolnir-vms
  1. Connect to tmux server socket
  2. Create session "mjolnir-vms"
  3. For each VM: create-window, get pane ID
  4. Bridge: VM PTY output -> tmux send to pane
           tmux pane input -> VM PTY input
```

This is significantly more complex. The tmux control protocol is not formally documented as a stable API, and the escape encoding for `%output` adds overhead.

#### Option D: Use SSH as the Transport Layer (Recommended Hybrid)

Mjolnir already has `mjolnir iroh ssh` which tunnels SSH over Iroh QUIC. SSH is the protocol that tmux and every terminal tool already understands perfectly.

```bash
# This already works:
tmux new-window -n "vm-abc" "mjolnir iroh ssh <ticket>"

# Or with the API-based approach, if SSH is configured:
tmux new-window -n "vm-abc" "ssh -o ProxyCommand='mjolnir proxy <ticket> --port 22' root@mjolnir"
```

**Benefits:**
- tmux, iTerm2, Warp, Ghostty all have first-class SSH support
- SSH provides its own channel multiplexing, port forwarding, agent forwarding
- `authorized_keys` already configured via `configure_ssh` vsock command
- ProxyCommand pattern lets any SSH client use Iroh as transport

**Trade-off:** Requires sshd running in the VM (adds ~2MB memory overhead, attack surface). But Mjolnir already provisions SSH keys via the `configure_ssh` command, so this is clearly an intended path.

---

## 3. Alternative Streaming Formats and Protocols

### 3.1 SSH Subsystems

SSH subsystems allow custom protocols to run over SSH channels. Instead of a shell, the client requests a named subsystem, and a corresponding program runs on the server.

```
# Server-side config (/etc/ssh/sshd_config):
Subsystem mjolnir /usr/local/bin/mjolnir-agent-subsystem

# Client-side:
ssh -s mjolnir user@host
```

**Relevance to Mjolnir:** A custom SSH subsystem could provide a structured JSON/binary protocol for agent communication -- separate from the interactive shell. An agent could open one SSH channel for shell interaction and another for structured commands, all multiplexed over a single SSH connection.

### 3.2 Mosh (Mobile Shell)

Mosh uses a different architecture:
- Runs `mosh-server` on the remote, which allocates a PTY and runs a terminal emulator (parsing ANSI output into a screen state)
- Transmits **screen state diffs** over UDP (using SSP -- State Synchronization Protocol)
- Client renders the current screen state, not a byte stream

**Key insight:** Mosh is roaming-resilient because it transmits state, not a stream. If packets are lost or the client reconnects, the screen state is simply retransmitted. The server maintains a full terminal state machine.

**Relevance to Mjolnir:** Iroh QUIC already provides reliable, ordered delivery and NAT traversal. Mosh's UDP-based approach solves problems that QUIC already handles. However, Mosh's **state synchronization** concept is valuable for AI agents -- an agent reconnecting to a session would benefit from getting the current screen state rather than replaying a byte stream.

### 3.3 Eternal Terminal (et)

Eternal Terminal takes a different approach from Mosh:
- Uses TCP (not UDP) with automatic reconnection
- Transmits raw PTY bytes (like SSH), not screen state diffs
- Maintains a replay buffer so reconnections can catch up
- Supports native scrollback, tmux-like features

**Relevance:** ET's replay buffer concept is useful for Mjolnir's agent integration. If an agent disconnects and reconnects, the server could replay buffered output.

### 3.4 Terminal Relay / Recordings

Tools like `script(1)`, `asciinema`, and `termrec` capture raw PTY output with timestamps:

```
# script(1) -- record a terminal session
script -q /tmp/session.log

# asciinema format (JSON lines):
[0.5, "o", "$ ls\r\n"]
[0.7, "o", "file1.txt  file2.txt\r\n"]
[2.1, "i", "exit\r\n"]
```

**Relevance:** Mjolnir could offer a recording/replay mode for PTY sessions. The guest agent already has all the bytes flowing through it; adding a timestamped ring buffer would enable:
- Session recording for auditing
- Agent replay (reconnect and catch up)
- Debugging (replay what happened in a VM)

### 3.5 ConPTY (Windows)

Windows ConPTY (pseudoconsole API) is only relevant if Mjolnir VMs run Windows. Currently they run Linux, so ConPTY is not applicable. Noted for completeness.

---

## 4. Agent-PTY Integration Patterns

This is the core question: how can an AI agent maintain a reference to a live PTY session and send/receive commands?

### 4.1 Pattern Analysis

| Pattern | Mechanism | Latency | Reliability | Complexity |
|---------|-----------|---------|-------------|------------|
| tmux send-keys | `tmux send-keys -t %N "cmd" Enter` | Low | High | Low |
| tmux capture-pane | `tmux capture-pane -t %N -p` | Low | Medium* | Low |
| expect/pexpect | Pattern matching on PTY stream | Low | Medium | Medium |
| script + tail | `script -q log` + read log | Medium | High | Low |
| Direct PTY fd | Open PTY master fd, read/write | Lowest | High | High |
| WebSocket API | Mjolnir's existing WS PTY | Low | High | Medium |
| MCP exec tool | Mjolnir's `exec` MCP tool | Medium | High | Lowest |

*capture-pane reliability is "medium" because timing-dependent -- you might capture before the command output appears.

### 4.2 Recommended: tmux send-keys + capture-pane (For Local Agents)

This is the most battle-tested pattern for AI agents interacting with terminals. Claude Code, Cursor, and similar tools already use this approach.

```bash
# Agent creates a named session
tmux new-session -d -s agent-vm-abc -n shell "mjolnir connect abc123"

# Agent sends a command
tmux send-keys -t agent-vm-abc:shell "ls -la /tmp" Enter

# Agent waits briefly, then captures output
sleep 0.5
tmux capture-pane -t agent-vm-abc:shell -p -S -50

# Agent can also check if a command is done by looking for the prompt
tmux capture-pane -t agent-vm-abc:shell -p | tail -1 | grep -q '^\$'
```

**Enhancement: Shell Integration Markers**

For more reliable command/output correlation, configure the shell inside the VM to emit OSC markers:

```bash
# In VM's .bashrc:
PS1='\[\e]133;A\a\]'$PS1
precmd() { printf '\e]133;C\a'; }
preexec() { printf '\e]133;B\a'; }
```

iTerm2's shell integration protocol (OSC 133) marks:
- `133;A` -- prompt start
- `133;B` -- command start (after user presses Enter)
- `133;C` -- command finished, output follows
- `133;D;N` -- command finished with exit code N

An agent parsing tmux capture output could reliably delimit command boundaries using these markers.

### 4.3 Recommended: Mjolnir exec MCP Tool (For Structured Agent Work)

For agents that need structured command execution (not interactive terminal sessions), the existing `exec` MCP tool is superior:

```json
{
  "tool": "exec",
  "params": {
    "vm_id": "abc-123",
    "command": "ls -la /tmp",
    "timeout": 30000
  }
}
```

Returns: `{ "exit_code": 0, "stdout": "...", "stderr": "..." }`

This is deterministic, has no timing issues, and provides structured output. The trade-off is that it cannot handle interactive programs (vim, top, etc.) or long-running processes that produce streaming output.

### 4.4 Hybrid: MCP PTY Session Tool (Proposed)

A new MCP tool that creates a persistent PTY session and allows send/receive:

```json
// Open a session
{ "tool": "pty_open", "params": { "vm_id": "abc-123" } }
// Returns: { "session_id": "pty-1", "channel": 3 }

// Send input
{ "tool": "pty_send", "params": { "session_id": "pty-1", "input": "ls -la\n" } }

// Read output (with timeout)
{ "tool": "pty_read", "params": { "session_id": "pty-1", "timeout_ms": 5000 } }
// Returns: { "output": "total 48\ndrwxr-xr-x ...", "eof": false }

// Close
{ "tool": "pty_close", "params": { "session_id": "pty-1" } }
```

**Architecture:** The Mjolnir API server would maintain open vsock PTY channels, buffer output, and expose them through the MCP protocol. The guest agent's `PtyManager` already supports multiple concurrent PTY channels (up to 255).

**Trade-offs:**
- Pro: Structured, no timing ambiguity, works over MCP
- Pro: Server-side buffering means agents can poll at their own pace
- Con: Requires server-side session state management
- Con: MCP is request/response, not streaming -- agents must poll for output
- Con: Buffer management (how much output to retain? when to drop?)

### 4.5 Alternative: WebSocket PTY for Agents

An agent could open a WebSocket connection to `/api/vms/<id>/pty` and maintain it as a persistent bidirectional stream. This is what the `mjolnir connect` CLI does.

```python
# Python agent example
import websockets, asyncio, json

async def agent_shell(vm_id, token):
    uri = f"wss://api.mjolnir.example.com/api/vms/{vm_id}/pty"
    headers = {"Authorization": f"Bearer {token}"}

    async with websockets.connect(uri, extra_headers=headers) as ws:
        # Send resize
        await ws.send(json.dumps({"type": "resize", "rows": 24, "cols": 80}))

        # Send command
        await ws.send(b"ls -la\n")

        # Read output
        output = b""
        while True:
            msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
            if isinstance(msg, bytes):
                output += msg
                if b"$ " in output:  # crude prompt detection
                    break

        print(output.decode())
```

**Trade-off:** Requires the agent to manage a persistent WebSocket connection and implement prompt detection. More complex than MCP exec but enables interactive sessions.

### 4.6 The Expect Pattern

The classic `expect` approach (Tcl expect, Python pexpect) works by:
1. Spawning a process with a PTY
2. Pattern-matching on the PTY output stream
3. Sending input when expected patterns appear

For Mjolnir, an "expect" layer could be built on top of either the WebSocket PTY or a tmux session:

```python
# Conceptual: expect over Mjolnir WebSocket
pty = MjolnirPty(vm_id="abc-123")
pty.expect(r'\$ ')           # wait for prompt
pty.sendline('apt update')
pty.expect(r'\$ ', timeout=60)  # wait for command to finish
print(pty.before)            # captured output
```

This is well-suited for automated provisioning scripts but fragile for general-purpose agent interaction (prompts vary, output timing is unpredictable).

---

## 5. Prior Art: How Modern Tools Handle Remote PTY

### 5.1 Warp

Warp is a GPU-accelerated terminal that treats terminal output as structured blocks:
- Each command and its output is a discrete "block"
- Blocks are individually selectable, copyable, searchable
- Warp uses a custom input editor (not a PTY for the input line)
- For remote sessions, Warp relies on SSH and has no custom protocol

**Relevance:** Warp's block model aligns with what agents need -- discrete command/output pairs. But Warp achieves this through shell integration (detecting PS1, prompt markers) rather than protocol changes. Mjolnir could adopt the same shell integration markers (OSC 133) inside VMs.

### 5.2 Ghostty

Ghostty is a native terminal emulator focused on correctness and performance:
- Uses a custom terminal emulation engine (libghostty, written in Zig)
- Supports standard PTY semantics
- Has experimental tmux control mode support
- No custom remote protocol; relies on SSH

**Relevance:** Ghostty's tmux -CC support means Mjolnir sessions running inside tmux will render correctly in Ghostty. No special integration needed.

### 5.3 Zellij

Zellij is a terminal multiplexer (like tmux) with some unique features:
- Plugin system (WASM plugins can interact with panes)
- Layout system (YAML/KDL files define pane arrangements)
- Built-in pane-level scrollback and search
- **No control mode equivalent** -- Zellij does not have a machine-readable protocol like tmux -CC

**Relevant features:**
- `zellij action write-chars "text"` -- send text to the focused pane
- `zellij action dump-screen /tmp/output.txt` -- capture pane content
- Plugin API allows reading/writing pane content programmatically

A Zellij plugin for Mjolnir could manage VM connections as panes, but Zellij's adoption is much smaller than tmux, and its plugin API is less stable.

### 5.4 Mosh

Already covered in section 3.2. Key addition: Mosh's roaming support (changing IP addresses, sleeping laptop) is already handled by Iroh's relay infrastructure. QUIC connections through Iroh relays survive network transitions.

### 5.5 Eternal Terminal (et)

Already covered in section 3.3. ET's approach of automatic reconnection with replay is achievable in Mjolnir by adding a ring buffer to the guest agent's PTY output path. When a client reconnects, replay the buffer.

### 5.6 Upterm / Tmate

Upterm and Tmate enable terminal sharing over the internet:
- **Tmate:** Fork of tmux that connects to a relay server. Provides a shareable SSH URL. Uses the tmux protocol internally.
- **Upterm:** Go-based, uses SSH as the transport. Supports both host and client modes.

**Architecture pattern (Tmate):**
```
User terminal <-> tmux <-> tmate relay server <-> viewer SSH connection
```

**Relevance:** This is architecturally similar to what Mjolnir already does. The Mjolnir API server acts as a relay between the WebSocket client and the vsock-connected VM. The key difference is that Tmate/Upterm use SSH as the viewer protocol, making them compatible with any SSH client. Mjolnir's `iroh ssh` command achieves the same thing.

### 5.7 ttyd / gotty

Web-based terminal sharing:
- **ttyd:** Runs a command (usually a shell) and exposes it as a WebSocket + xterm.js web page
- **gotty:** Same concept, Go-based

These are xterm.js-style (browser-based terminal emulation), which is the opposite of Mjolnir's raw PTY approach. Less relevant for agent/tmux integration.

---

## 6. Concrete Recommendations

### Priority 1: Document the SSH Path (Low effort, High impact)

The `mjolnir iroh ssh` command is already the best integration point for tmux and iTerm2. Document this as the recommended way to use Mjolnir with tmux:

```bash
# One-liner to open a VM in a new tmux window
tmux new-window -n "vm-$(echo $VM_ID | cut -c1-8)" \
  "mjolnir iroh ssh $TICKET"

# For tmux -CC (iTerm2 integration):
# Just use tmux normally -- iTerm2 handles the rendering
tmux -CC new-session -s mjolnir
tmux new-window -n "my-vm" "mjolnir iroh ssh $TICKET"
```

**Trade-off:** Requires sshd in the VM. But this is already the standard Mjolnir setup path.

### Priority 2: Add PTY Output Buffering to Guest Agent (Medium effort, High impact)

Add a configurable ring buffer to the PTY output path in the guest agent. This enables:
- Reconnection with replay (both Iroh and WebSocket paths)
- Agent polling without missing output
- Session recording

**Implementation:** In `vsock.rs`, the PTY output forwarding task (`tokio::spawn` at line 590) reads from `pty_reader` and sends frames. Add a `VecDeque<u8>` ring buffer (e.g., 256KB) that retains recent output. Expose a `pty_replay` vsock command that sends buffered content.

**Trade-off:** Memory overhead per PTY session (256KB default, configurable). Must handle buffer overflow gracefully.

### Priority 3: MCP PTY Session Tools (Medium effort, Medium impact)

Extend the MCP server with `pty_open`, `pty_send`, `pty_read`, `pty_close` tools. The API server already has vsock PTY channel management. The MCP tools would:
1. Open a vsock PTY channel via `pty_open`
2. Buffer output server-side
3. Let agents poll with `pty_read`
4. Accept input via `pty_send`

**Trade-off:** Adds complexity to the Elixir API server (session state, buffer management, timeouts). But provides the cleanest agent integration path.

### Priority 4: Shell Integration Markers in VM Base Image (Low effort, Medium impact)

Pre-configure the VM base image with iTerm2/OSC 133 shell integration:

```bash
# /etc/profile.d/mjolnir-shell-integration.sh
if [ -n "$BASH_VERSION" ]; then
    __mjolnir_prompt_command() {
        local exit_code=$?
        printf '\e]133;D;%d\a' "$exit_code"
        printf '\e]133;A\a'
    }
    __mjolnir_preexec() {
        printf '\e]133;C\a'
    }
    PROMPT_COMMAND="__mjolnir_prompt_command"
    trap '__mjolnir_preexec' DEBUG
fi
```

This makes command boundaries machine-detectable for agents reading captured pane output.

**Trade-off:** Slightly pollutes the byte stream with escape sequences. Agents not expecting them will see garbage. Could be opt-in via env var.

### Priority 5: `mjolnir tmux` Subcommand (Medium effort, Medium impact)

A convenience command that automates tmux session management:

```bash
# Open VM in a new tmux pane
mjolnir tmux connect abc123

# Open VM in a new tmux window
mjolnir tmux connect abc123 --window

# List VM sessions
mjolnir tmux list

# Attach to existing session
mjolnir tmux attach abc123
```

Under the hood, this just wraps `tmux new-window "mjolnir iroh ssh ..."` with proper naming, session management, and cleanup.

**Trade-off:** Thin wrapper; value is mainly UX polish and discoverability.

---

## 7. Architecture Decision: Which Transport for Agent Sessions?

### Option A: SSH Everywhere

Use SSH as the universal transport. Agents, tmux, and interactive users all go through `mjolnir iroh ssh`.

| Pros | Cons |
|------|------|
| Universal compatibility | Requires sshd in every VM |
| tmux/iTerm2 work perfectly | SSH handshake latency (~200ms extra) |
| Agent tools (ansible, fabric) work | Key management complexity |
| ProxyCommand pattern is standard | Cannot multiplex multiple shells on one conn* |

*Actually SSH can multiplex via ControlMaster/ControlPath.

### Option B: Native Protocol + SSH for Integration

Keep the Mjolnir shell protocol for direct connections, use SSH when tmux/agent integration is needed.

| Pros | Cons |
|------|------|
| Lower latency for direct connections | Two code paths to maintain |
| No sshd dependency for basic connect | Agents must choose which path |
| Shell protocol is simpler than SSH | tmux integration requires SSH |
| Vsock PTY channels give server-side multiplexing | Complexity |

### Option C: MCP-Native Agent Sessions

Keep interactive sessions as-is (SSH or native protocol), add MCP tools for agent-specific workflows.

| Pros | Cons |
|------|------|
| Clean separation of concerns | MCP is polling, not streaming |
| Agents use structured API, humans use terminals | Output buffering complexity |
| No PTY management in agent code | Cannot handle interactive programs |
| Works with any MCP client | |

### Recommendation: Option C (MCP-Native) + Option A (SSH) as Complementary Layers

- **Interactive human use:** `mjolnir iroh ssh` + tmux for multiplexing. This works today.
- **Agent structured commands:** MCP `exec` tool. This works today.
- **Agent interactive sessions:** New MCP `pty_*` tools for cases where `exec` is insufficient. Build this.
- **Agent terminal monitoring:** tmux `send-keys` + `capture-pane` when the agent needs a live terminal view. Already possible.

This avoids building a new protocol and leverages existing infrastructure for each use case.

---

## 8. Summary of Key Findings

1. **Mjolnir's raw PTY byte streaming is well-architected** for terminal integration. The data is already just bytes -- no xterm.js-style emulation layer gets in the way.

2. **tmux -CC integration works today** by running `mjolnir iroh ssh` or `mjolnir connect` inside tmux panes. No protocol changes needed. iTerm2 handles rendering natively.

3. **The SSH path (`mjolnir iroh ssh`) is the most integration-friendly** transport. It works with tmux, iTerm2, Warp, Ghostty, ansible, fabric, rsync, scp, and every other SSH-aware tool. The `ProxyCommand` pattern (`mjolnir iroh proxy`) makes this transparent.

4. **For AI agents, the MCP `exec` tool is sufficient for most cases.** For interactive sessions, add MCP `pty_*` tools that manage server-side PTY channels and output buffers. For terminal-centric agents (Claude Code in tmux), use `tmux send-keys` + `capture-pane`.

5. **Output buffering in the guest agent** is the highest-leverage improvement. It enables reconnection replay, agent polling, and session recording -- all from a single ~100-line change to the PTY output forwarding task.

6. **Shell integration markers (OSC 133)** in the VM base image would significantly improve agent reliability when parsing terminal output, with minimal implementation cost.

---

## References

- `mjolnir/native/mjolnir_protocol/src/lib.rs` -- Binary wire protocol definition
- `mjolnir/native/mjolnir_guest_agent/src/pty.rs` -- PTY session management (openpty/fork)
- `mjolnir/native/mjolnir_guest_agent/src/iroh.rs` -- Iroh shell server (QUIC endpoint)
- `mjolnir/native/mjolnir_guest_agent/src/vsock.rs` -- Vsock listener with PTY channel multiplexing
- `mjolnir/native/mjolnir_client/src/connect.rs` -- Client-side connection (Iroh QUIC + WebSocket PTY)
- `mjolnir/native/mjolnir_client/src/mcp.rs` -- MCP server with exec and await_pty tools
- `mjolnir/native/mjolnir_gateway/src/main.rs` -- Web gateway (HTTP-to-Iroh TCP proxy)
- tmux control mode: `man tmux` section on "CONTROL MODE"
- iTerm2 tmux integration: https://iterm2.com/documentation-tmux-integration.html
- OSC 133 (Shell Integration): https://iterm2.com/documentation-shell-integration.html
- Mosh SSP: https://mosh.org/mosh-paper.pdf
- Iroh: https://iroh.computer
