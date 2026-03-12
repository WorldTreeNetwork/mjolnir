# tmux -CC (Control Mode) and iTerm2 Integration

## Research: Multiplexing Remote PTY Sessions from Cloud VMs

**Date:** 2026-03-10
**Context:** Mjolnir microVM platform -- bridging WebSocket PTY connections from cloud VMs into native iTerm2 tabs/panes via tmux control mode.

---

## Table of Contents

1. [tmux Control Mode Protocol Deep Dive](#1-tmux-control-mode-protocol-deep-dive)
2. [Programmatic tmux -CC Control](#2-programmatic-tmux--cc-control)
3. [Bridging WebSocket PTY to tmux](#3-bridging-websocket-pty-to-tmux)
4. [Session Persistence and Reconnection](#4-session-persistence-and-reconnection)
5. [Multi-Agent Scenarios](#5-multi-agent-scenarios)
6. [Limitations and Gotchas](#6-limitations-and-gotchas)
7. [Recommended Architecture for Mjolnir](#7-recommended-architecture-for-mjolnir)

---

## 1. tmux Control Mode Protocol Deep Dive

### 1.1 Entering Control Mode

tmux control mode is activated with the `-C` flag. The double flag `-CC` is what iTerm2 uses:

- **`tmux -C`**: Control mode with echo enabled (useful for debugging/testing)
- **`tmux -CC`**: Control mode with echo disabled. On entry, tmux emits the DCS sequence `\033P1000p`. On exit, it sends `%exit` followed by the DCS terminator `\033\\`.

The DCS (Device Control String) envelope is how iTerm2 detects that it should enter tmux integration mode. When iTerm2 sees `\033P1000p` in a terminal session's output, it activates its TmuxGateway parser and switches the connection from normal terminal emulation to structured control mode communication.

```
# What iTerm2 sees when you run `tmux -CC`:
\033P1000p          <-- DCS: "I am a tmux control mode client"
%begin 1709876543 1 1
%end 1709876543 1 1
%session-changed $0 default
...                 <-- structured protocol from here on
```

### 1.2 Command-Response Protocol

Commands are sent as plain text lines (standard tmux commands). Every command response is wrapped in guard markers:

```
# Client sends:
list-windows -F '#{window_id} #{window_name}'

# Server responds:
%begin 1709876543 42 1
@0 bash
@1 vim
%end 1709876543 42 1
```

The guard format is:
```
%begin <timestamp> <command-number> <flags>
[output lines]
%end <timestamp> <command-number> <flags>
```

On error:
```
%begin <timestamp> <command-number> <flags>
[error message]
%error <timestamp> <command-number> <flags>
```

Fields:
- **timestamp**: Unix epoch seconds
- **command-number**: Monotonically increasing, used to correlate begin/end pairs
- **flags**: Bit 0 = 1 if client-originated, 0 if server-originated

An **empty line** sent to tmux causes the control client to detach. This is important -- accidental blank lines will disconnect.

### 1.3 Pane Output Notifications

Pane output is delivered asynchronously via `%output` notifications:

```
%output %0 hello world\015\012
%output %3 $ ls\015\012file1  file2\015\012
```

Format: `%output %<pane-id> <escaped-data>`

Character escaping: All bytes with value < 32 (space) and backslash itself are escaped as octal (`\015` for CR, `\012` for LF, `\134` for backslash).

With flow control enabled (tmux 3.2+), extended output includes latency metadata:
```
%extended-output %0 150 : output data here
```
Format: `%extended-output %<pane-id> <milliseconds-behind> : <data>`

### 1.4 Notification Types

tmux sends these asynchronous notifications to control clients:

| Notification | Format | Purpose |
|---|---|---|
| `%output` | `%<pane> <data>` | Pane produced output |
| `%extended-output` | `%<pane> <ms-behind> : <data>` | Output with latency (3.2+) |
| `%window-add` | `@<window>` | Window created in attached session |
| `%window-close` | `@<window>` | Window closed in attached session |
| `%window-renamed` | `@<window> <name>` | Window renamed |
| `%window-pane-changed` | `@<window> %<pane>` | Active pane changed in window |
| `%session-changed` | `$<session> <name>` | Attached session changed |
| `%session-renamed` | `$<session> <name>` | Session renamed |
| `%sessions-changed` | (none) | Session created or destroyed |
| `%session-window-changed` | `$<session> @<window>` | Active window changed |
| `%layout-change` | `@<win> <layout> <vis-layout> <flags>` | Window layout changed |
| `%pane-mode-changed` | `%<pane>` | Pane mode changed (e.g., copy mode) |
| `%pause` | `%<pane>` | Pane output paused (flow control) |
| `%continue` | `%<pane>` | Pane output resumed |
| `%client-session-changed` | `<client> $<session> <name>` | Another client changed session |
| `%client-detached` | `<client>` | Another client detached |
| `%unlinked-window-add` | `@<window>` | Window added in other session |
| `%unlinked-window-close` | `@<window>` | Window closed in other session |
| `%unlinked-window-renamed` | `@<window> <name>` | Window renamed in other session |
| `%subscription-changed` | `<args> : <value>` | Format subscription updated (3.2+) |
| `%paste-buffer-changed` | `<buffer-name>` | Paste buffer modified |
| `%paste-buffer-deleted` | `<buffer-name>` | Paste buffer deleted |
| `%exit` | (optional reason) | Control client should exit |

### 1.5 Addressing Scheme

tmux uses prefixed numeric IDs for unambiguous addressing:

- **Sessions**: `$0`, `$1`, `$2` ...
- **Windows**: `@0`, `@1`, `@2` ...
- **Panes**: `%0`, `%1`, `%2` ...

These IDs are globally unique and stable within a server instance. Always use IDs rather than names or indices -- names can be duplicated and indices change as items are reordered.

### 1.6 How iTerm2 Uses the Protocol (TmuxGateway internals)

From analysis of iTerm2's `TmuxGateway.m` source:

1. **Connection startup**: iTerm2 detects `\033P1000p` DCS in terminal output, instantiates a `TmuxGateway` and `TmuxController`.

2. **Initial handshake**: iTerm2 sends a batch of initial commands to discover the session state:
   - `list-sessions -F '#{session_id} ...'`
   - `list-windows -F '#{window_id} ...'`
   - `list-panes -F '#{pane_id} ...'`
   - Layout queries to understand pane geometry

3. **Window mapping**: Each tmux window becomes an iTerm2 tab (or window, per user preference). Each tmux pane within a window becomes an iTerm2 split pane.

4. **Output routing**: `%output %<pane-id> <data>` notifications are parsed, the octal escapes are decoded, and the data is fed to the corresponding iTerm2 session's terminal emulator (VT100 parser).

5. **Input routing**: Keystrokes in an iTerm2 pane are sent back to tmux via `send-keys -t %<pane-id> -H <hex-bytes>`. The `-H` flag sends raw hex-encoded bytes, avoiding key-name interpretation issues.

6. **Command queuing**: Commands are queued until tmux signals readiness via `%session-changed`. A `_canWrite` flag gates transmission. Multiple commands can be batched with semicolon separators via `sendCommandList:`.

7. **Version compatibility**: iTerm2 checks the tmux version for feature support:
   - UTF-8 support requires tmux >= 2.2
   - Surrogate pair support requires tmux != 2.2 exactly
   - Subscription/flow-control support requires tmux >= 3.2

---

## 2. Programmatic tmux -CC Control

### 2.1 Creating Windows and Panes from Code

Since the control mode protocol is text-based, any process that can write to tmux's stdin can issue commands:

```bash
# Create a new window (appears as new iTerm2 tab)
echo "new-window -n 'vm-abc123'" > /path/to/tmux-control-input

# Split the current window (appears as iTerm2 split pane)
echo "split-window -h -t @0" > /path/to/tmux-control-input

# Run a command in a new window
echo "new-window -n 'vm-abc123' 'mjolnir connect abc123'" > /path/to/tmux-control-input
```

### 2.2 Architecture for MCP Tool Integration

The key insight: the control mode client (the process that ran `tmux -CC`) owns the stdin/stdout pipes to tmux. To inject commands from an external process (like an MCP tool), you have several options:

**Option A: Use `tmux` CLI commands (recommended for simplicity)**

tmux commands can be sent from any process via the tmux socket, regardless of control mode. The control client will receive the notifications:

```typescript
// MCP tool handler: open a new iTerm2 tab connected to a VM
async function openVmTab(vmId: string): Promise<void> {
  const vmName = `vm-${vmId.slice(0, 8)}`;

  // This creates a new window in the tmux session.
  // Because iTerm2 is attached via -CC, it automatically
  // becomes a new iTerm2 tab.
  await exec(`tmux new-window -t mjolnir -n '${vmName}' \
    'mjolnir connect ${vmId}'`);
}

// Split an existing VM tab to add a second shell
async function splitVmTab(vmId: string): Promise<void> {
  // Find the window by name
  const windowId = await exec(
    `tmux list-windows -t mjolnir -F '#{window_id} #{window_name}' \
     | grep 'vm-${vmId.slice(0, 8)}' | awk '{print $1}'`
  );

  await exec(`tmux split-window -t ${windowId} -h \
    'mjolnir connect ${vmId}'`);
}
```

This works because `tmux` CLI commands go through the tmux server socket (`/tmp/tmux-$UID/default` or wherever the server listens). The server processes them and sends notifications to the control client (iTerm2), which creates the corresponding UI elements.

**Option B: Write directly to the control client's stdin**

If you need to bypass the tmux CLI and write commands directly:

```typescript
// Less common, but useful if you need to control
// the exact command sequence or avoid tmux CLI overhead
import { createWriteStream } from 'fs';

// The control client's stdin must be accessible
// (e.g., via a named pipe or fd passing)
const tmuxInput = createWriteStream('/tmp/mjolnir-tmux-control.pipe');

function sendTmuxCommand(cmd: string): void {
  tmuxInput.write(cmd + '\n');
}

sendTmuxCommand("new-window -n 'vm-abc123' 'mjolnir connect abc123'");
```

**Option C: iTerm2 Python API (if available)**

iTerm2 has a Python scripting API, though its tmux integration surface is limited:

```python
import iterm2

async def create_vm_tab(connection, vm_id):
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window
    # Create a new tab and run a command in it
    await window.async_create_tab(
        command=f"mjolnir connect {vm_id}"
    )
```

However, this creates a local iTerm2 tab, not a tmux-integrated one. For tmux integration, Option A (tmux CLI) is the correct approach.

### 2.3 Recommended MCP Tool Design

```typescript
// MCP tool: mjolnir_open_vm_terminal
//
// Ensures a tmux -CC session exists, then creates a new
// window connected to the specified VM.

interface OpenVmTerminalArgs {
  vmId: string;
  sessionName?: string;  // default: "mjolnir"
  split?: 'horizontal' | 'vertical';  // if set, split existing window
  targetWindow?: string;  // window to split (required if split is set)
}

async function openVmTerminal(args: OpenVmTerminalArgs): Promise<string> {
  const session = args.sessionName ?? 'mjolnir';
  const vmName = `vm-${args.vmId.slice(0, 8)}`;

  // 1. Check if the tmux session exists
  const sessionExists = await exec(
    `tmux has-session -t ${session} 2>/dev/null && echo yes || echo no`
  );

  if (sessionExists.trim() === 'no') {
    // Session does not exist. The user needs to start tmux -CC first.
    // We cannot programmatically start tmux -CC because it requires
    // an interactive terminal (iTerm2) to attach to.
    return `No tmux session "${session}" found. ` +
      `Run "tmux -CC new -s ${session}" in iTerm2 first.`;
  }

  // 2. Build the bridge command that connects WebSocket PTY to this pane
  const bridgeCmd = `mjolnir connect ${args.vmId}`;

  // 3. Create window or split
  if (args.split && args.targetWindow) {
    const flag = args.split === 'horizontal' ? '-h' : '-v';
    await exec(
      `tmux split-window -t ${args.targetWindow} ${flag} '${bridgeCmd}'`
    );
    return `Split ${args.targetWindow} ${args.split}ly with ${vmName}`;
  } else {
    await exec(
      `tmux new-window -t ${session} -n '${vmName}' '${bridgeCmd}'`
    );
    return `Opened new tab "${vmName}" in session "${session}"`;
  }
}
```

---

## 3. Bridging WebSocket PTY to tmux

The core challenge: `mjolnir connect <vm_id>` produces a WebSocket-based PTY stream. This stream must become the I/O of a tmux pane so that iTerm2 can render it natively.

### 3.1 Approach Comparison

| Approach | Complexity | Latency | Reliability | Terminal Correctness |
|----------|-----------|---------|-------------|---------------------|
| A. Bridge process (recommended) | Medium | Low | High | Full |
| B. `pipe-pane` | Low | Medium | Medium | Partial |
| C. PTY pair + socat | Medium | Low | Medium | Full |
| D. Named pipes (FIFO) | Low | Low | Low | Partial (no bidirectional resize) |

### 3.2 Approach A: Bridge Process (Recommended)

The bridge process is a small program that:
1. Connects to the VM via WebSocket
2. Allocates a local PTY pair (master/slave)
3. tmux runs with the slave end as the pane's terminal
4. Forwards data bidirectionally: WebSocket <-> PTY master

```
                    +------------------+
 iTerm2 <--CC--> tmux server          |
                    |                  |
                    | pane %3 uses     |
                    | slave PTY end    |
                    |                  |
              +-----+------+          |
              | PTY pair   |          |
              | master/slave|         |
              +-----+------+          |
                    |                  |
              +-----+------+          |
              | mjolnir    |          |
              | bridge     |          |
              | process    |          |
              +-----+------+          |
                    |                  |
                    | WebSocket        |
                    |                  |
              +-----+------+          |
              | Mjolnir    |          |
              | microVM    |          |
              +-----------+           |
                                      |
```

Implementation sketch in TypeScript/Bun:

```typescript
// mjolnir-bridge.ts
// Bridges a WebSocket PTY to a local PTY for tmux consumption.

import { spawn } from 'node:child_process';
import { openpty } from 'node-pty';  // or native bindings

async function bridge(vmId: string): Promise<void> {
  // 1. Create a PTY pair
  const pty = openpty();
  // pty.master: fd for our process to read/write
  // pty.slave: fd that tmux will use as the pane's terminal

  // 2. Connect to VM WebSocket
  const ws = new WebSocket(`wss://mjolnir.example.com/ws/vm/${vmId}`);

  // 3. Forward WebSocket -> PTY master (VM output -> tmux pane)
  ws.onmessage = (event) => {
    const data = typeof event.data === 'string'
      ? Buffer.from(event.data)
      : Buffer.from(event.data as ArrayBuffer);
    fs.writeSync(pty.master, data);
  };

  // 4. Forward PTY master -> WebSocket (user input -> VM)
  const readStream = fs.createReadStream('', { fd: pty.master });
  readStream.on('data', (chunk: Buffer) => {
    ws.send(chunk);
  });

  // 5. Handle resize (SIGWINCH on slave PTY)
  // tmux will set the slave PTY size. We detect it and
  // forward to the VM.
  process.on('SIGWINCH', () => {
    const size = pty.getSize();  // read from slave
    ws.send(JSON.stringify({
      type: 'resize',
      cols: size.cols,
      rows: size.rows
    }));
  });

  // 6. Handle cleanup
  ws.onclose = () => process.exit(0);
  process.on('SIGTERM', () => ws.close());
}
```

However, the simpler and more practical approach is to make `mjolnir connect` itself be the bridge process. When tmux runs `mjolnir connect <vm_id>` as the pane command, the process's stdin/stdout ARE the PTY slave. tmux manages the PTY pair automatically:

```typescript
// mjolnir connect command -- simplified bridge
// tmux creates the PTY pair. This process just bridges
// its own stdin/stdout to the WebSocket.

async function connectCommand(vmId: string): Promise<void> {
  // Put stdin in raw mode so we get individual keystrokes
  process.stdin.setRawMode(true);
  process.stdin.resume();

  const ws = new WebSocket(`wss://mjolnir.example.com/ws/vm/${vmId}`);

  // VM output -> stdout (which is the PTY slave, managed by tmux)
  ws.onmessage = (event) => {
    process.stdout.write(Buffer.from(event.data as ArrayBuffer));
  };

  // stdin (PTY slave, keystrokes from tmux) -> VM
  process.stdin.on('data', (chunk: Buffer) => {
    ws.send(chunk);
  });

  // Handle resize: SIGWINCH is sent when tmux resizes the pane
  process.on('SIGWINCH', () => {
    const { columns, rows } = process.stdout;
    ws.send(JSON.stringify({
      type: 'resize',
      cols: columns,
      rows: rows
    }));
  });

  ws.onclose = () => {
    process.stdin.setRawMode(false);
    process.exit(0);
  };

  ws.onerror = (err) => {
    process.stderr.write(`Connection error: ${err.message}\n`);
    process.exit(1);
  };
}
```

This is the cleanest approach. tmux handles all PTY management. The `mjolnir connect` process is a simple stdin/stdout <-> WebSocket bridge.

### 3.3 Approach B: pipe-pane

tmux's `pipe-pane` command connects a pane's I/O to a shell command:

```bash
# -I: connect command's stdout to pane input
# -O: connect pane's output to command's stdin
tmux pipe-pane -t %3 -IO 'mjolnir-ws-bridge vm-abc123'
```

Limitations:
- `pipe-pane` runs a shell command, not a full PTY bridge
- No clean resize signaling
- The piped process does not have a PTY, so programs expecting a terminal will misbehave
- Latency: data passes through an extra pipe layer
- One pipe per direction; replacing an active pipe disconnects the old one

This approach is viable for simple log-streaming use cases but not suitable for interactive terminal sessions.

### 3.4 Approach C: PTY Pair + socat

Use `socat` to bridge between a PTY and a WebSocket (or TCP proxy):

```bash
# Create a PTY pair and bridge one end to a WebSocket via an intermediate TCP hop
socat PTY,link=/tmp/vm-abc123.pty,raw,echo=0 \
  EXEC:"websocat wss://mjolnir.example.com/ws/vm/abc123"

# Then tell tmux to use the PTY
tmux respawn-pane -t %3 "cat /tmp/vm-abc123.pty"
```

This works but adds complexity and fragility. The custom bridge process (Approach A) is more robust and gives you control over resize propagation, reconnection logic, and error handling.

### 3.5 Approach D: Named Pipes (FIFO)

```bash
mkfifo /tmp/vm-in /tmp/vm-out

# Bridge process writes VM output to vm-out, reads user input from vm-in
mjolnir-bridge --vm abc123 --in /tmp/vm-in --out /tmp/vm-out &

# tmux pane reads from vm-out and writes to vm-in
tmux respawn-pane -t %3 "cat /tmp/vm-out & cat > /tmp/vm-in"
```

This is fragile: no resize handling, broken pipe issues, no PTY semantics (no raw mode, no SIGWINCH). Not recommended.

### 3.6 Resize Propagation Chain

The full resize chain in the recommended architecture:

```
User resizes iTerm2 window/pane
  --> iTerm2 sends `refresh-client -C WxH` to tmux
    --> tmux resizes the pane's PTY slave (ioctl TIOCSWINSZ)
      --> kernel sends SIGWINCH to the bridge process
        --> bridge reads new size from stdout.columns/rows
          --> bridge sends resize message over WebSocket
            --> Mjolnir VM agent resizes the VM's PTY
```

This chain works automatically with Approach A because tmux manages the PTY natively.

---

## 4. Session Persistence and Reconnection

### 4.1 How tmux -CC Handles Disconnections

When an iTerm2 tmux -CC connection drops (network failure, laptop sleep, SSH disconnect):

1. **tmux server persists**: The tmux server continues running on the remote host. All panes keep their processes alive.
2. **Pane processes keep running**: The `mjolnir connect` bridge processes in each pane continue running (they have their own WebSocket connections to VMs).
3. **iTerm2 tabs disappear**: The native tabs/panes close in iTerm2.
4. **Reattach restores everything**: Running `tmux -CC attach -t mjolnir` causes:
   - iTerm2 queries the session state (windows, panes, layouts)
   - Recreates all tabs and split panes
   - Reconnects output routing
   - The terminal history (scrollback) in each pane is preserved

### 4.2 Leveraging tmux Persistence for VM Reconnection

The architecture naturally supports reconnection at two levels:

**Level 1: iTerm2 <-> tmux reconnection**

This is automatic. `tmux -CC attach` restores the full UI state.

**Level 2: Bridge process <-> VM reconnection**

The `mjolnir connect` bridge process should implement reconnection logic:

```typescript
async function connectWithReconnect(vmId: string): Promise<void> {
  let retryCount = 0;
  const maxRetries = 10;
  const baseDelay = 1000;

  while (retryCount < maxRetries) {
    try {
      process.stdout.write(`\r\n[Connecting to VM ${vmId}...]\r\n`);
      await connectOnce(vmId);
      // If connectOnce returns cleanly, the VM shut down intentionally
      process.stdout.write(`\r\n[VM ${vmId} disconnected]\r\n`);
      return;
    } catch (err) {
      retryCount++;
      const delay = Math.min(baseDelay * Math.pow(2, retryCount), 30000);
      process.stdout.write(
        `\r\n[Connection lost. Retry ${retryCount}/${maxRetries} ` +
        `in ${delay / 1000}s...]\r\n`
      );
      await sleep(delay);
    }
  }
  process.stdout.write(`\r\n[Failed to reconnect after ${maxRetries} attempts]\r\n`);
}
```

**Level 3: Full stack reconnection scenario**

```
1. User closes laptop lid
2. SSH connection drops
3. tmux -CC detaches (iTerm2 tabs disappear)
4. tmux server keeps running
5. Bridge processes keep running (WebSocket to VM stays up if server is local)
   -- OR bridge processes detect WS disconnect and enter retry loop
6. User opens laptop
7. User runs: tmux -CC attach -t mjolnir
8. iTerm2 recreates all tabs/panes
9. Bridge processes are still connected (or have reconnected)
10. Full state restored -- user sees all VMs exactly as before
```

### 4.3 Session Naming Conventions

For Mjolnir, a structured session naming scheme aids automation:

```
Session:  mjolnir
Windows:  vm-<short-id>     (one per VM)
Panes:    automatically numbered by tmux (%0, %1, ...)
```

Window names can encode metadata via tmux user options:

```bash
# Store VM ID as a user option on the window
tmux set-option -t @3 @vm-id "abc123-def456-..."
tmux set-option -t @3 @vm-name "production-api"

# Retrieve later
tmux show-option -v -t @3 @vm-id
```

---

## 5. Multi-Agent Scenarios

### 5.1 Problem Statement

Multiple AI agents (Claude Code instances, copilots, CI agents) may need simultaneous PTY access to the same VM. The question is whether to share tmux sessions or use separate connections.

### 5.2 Option A: Separate tmux Windows per Agent (Recommended)

Each agent gets its own tmux window (iTerm2 tab), each running its own `mjolnir connect` bridge to the same VM:

```
tmux session "mjolnir"
  @0: "agent-1-vm-abc"  --> mjolnir connect abc123 (agent 1's PTY)
  @1: "agent-2-vm-abc"  --> mjolnir connect abc123 (agent 2's PTY)
  @2: "human-vm-abc"    --> mjolnir connect abc123 (human's PTY)
```

The VM side must support multiple PTY sessions. Each connection gets an independent shell session on the VM.

**Pros:**
- Complete isolation between agents
- Each agent has its own shell state, working directory, environment
- No interference between concurrent commands
- Natural mapping to iTerm2 tabs

**Cons:**
- Multiple WebSocket connections per VM
- No shared terminal state (cannot see what other agents typed)
- Higher resource usage on the VM (multiple shell processes)

### 5.3 Option B: Shared tmux Pane with Read-Only Observers

One agent owns the pane, others observe via tmux's built-in session sharing:

```bash
# Primary agent creates the session
tmux new-session -s vm-abc123 'mjolnir connect abc123'

# Observer agents attach read-only
tmux attach -t vm-abc123 -r
```

In control mode, the observer would attach with:
```bash
tmux -CC attach -t vm-abc123 -r
```

**Pros:**
- Single WebSocket connection
- All agents see the same terminal output
- Lower VM resource usage

**Cons:**
- Only one agent can type at a time (or they interleave destructively)
- Read-only observers cannot interact
- Complex coordination required for turn-taking
- Does not map well to the iTerm2 tab model (shared session means shared view)

### 5.4 Option C: Nested tmux on the VM

Run tmux inside the VM, with each agent connecting to a different window in the VM-side tmux:

```
Local tmux (iTerm2 -CC)
  @0: mjolnir connect abc123
       |
       v
  VM's tmux session
    @0: agent-1 shell
    @1: agent-2 shell
    @2: shared-monitoring
```

**Pros:**
- Single WebSocket connection with multiplexed sessions inside
- VM-side session persistence (survives bridge reconnection)
- Agents can share a monitoring pane while having private shells

**Cons:**
- Nested tmux key binding conflicts (need prefix remapping)
- Extra complexity layer
- Terminal resize must propagate through two tmux levels
- iTerm2 only sees the outer tmux structure

### 5.5 Recommended Multi-Agent Architecture

For Mjolnir, Option A (separate windows) is recommended because:

1. It is simplest to implement and debug
2. Agent isolation prevents interference
3. iTerm2 integration is clean (each VM+agent = one tab)
4. The VM PTY multiplexing is handled at the Mjolnir platform level, not the terminal level

The MCP tool interface would look like:

```typescript
// Each agent call specifies who they are
interface OpenTerminalArgs {
  vmId: string;
  agentId?: string;   // "agent-1", "human", etc.
  sessionName?: string;
}

async function openTerminal(args: OpenTerminalArgs): Promise<string> {
  const session = args.sessionName ?? 'mjolnir';
  const agentLabel = args.agentId ?? 'default';
  const windowName = `${agentLabel}-vm-${args.vmId.slice(0, 8)}`;

  await exec(`tmux new-window -t ${session} -n '${windowName}' \
    'mjolnir connect ${args.vmId}'`);

  return `Opened terminal "${windowName}" in session "${session}"`;
}
```

---

## 6. Limitations and Gotchas

### 6.1 Terminal Size Negotiation

**The smallest-client problem**: tmux sizes windows to fit the smallest attached client. If a control mode client has not set its size via `refresh-client -C`, it may constrain all windows.

Mitigation:
```bash
# Tell tmux this control client's size (or that it should be ignored)
tmux refresh-client -C 200x50

# Or use the ignore-size flag so this client does not constrain others
tmux refresh-client -f ignore-size
```

iTerm2 handles this automatically, sending `refresh-client -C WxH` whenever a tab/pane resizes. But if you have non-iTerm2 clients attached to the same session, the smallest-client rule applies.

**Per-window sizing** (tmux 3.1+): The `window-size` option can be set to `manual` or `latest`, which helps when multiple clients with different sizes are attached:

```bash
tmux set-option -g window-size latest  # size to most recently active client
```

### 6.2 Unicode and Character Encoding

**Known issues:**
- tmux control mode escapes all bytes < 32 as octal. UTF-8 multi-byte sequences where individual bytes happen to be < 128 are handled correctly (only control characters are escaped). But the octal escaping is byte-level, not character-level.
- tmux 2.2 had broken surrogate pair handling. iTerm2 explicitly checks for this version.
- Wide characters (CJK, emoji) may cause display width mismatches between tmux's tracking and iTerm2's rendering. tmux uses its own `wcwidth` implementation which may disagree with iTerm2.

Mitigation:
- Use tmux >= 3.2 for best Unicode support
- Ensure `LANG` and `LC_ALL` are set to UTF-8 locales on both local and remote sides
- Test with CJK text and emoji if your users may encounter them

### 6.3 Performance with High-Throughput Output

**The problem**: A VM running `cat /dev/urandom` or a verbose build can flood the control mode channel. tmux mitigates this but the architecture matters.

**tmux-side throttling** (from `control.c` source analysis):
- Output is buffered in per-pane queues of `control_block` structures
- A fairness algorithm divides available buffer space across panes: `limit = space / pending_count / 3` (the factor of 3 accounts for octal escape overhead)
- Minimum write size: 32 bytes (`CONTROL_WRITE_MINIMUM`)
- Buffer watermarks: low = 512 bytes, high = 8192 bytes (`CONTROL_BUFFER_LOW` / `CONTROL_BUFFER_HIGH`)
- Age-based throttling triggers at 300 seconds (`CONTROL_MAXIMUM_AGE`)

**Flow control** (tmux 3.2+ with `refresh-client -f pause-after=<seconds>`):
- tmux pauses pane output if it falls behind by the specified threshold
- Sends `%pause %<pane>` notification
- Client sends `refresh-client -A '%<pane>:continue'` to resume
- iTerm2 uses this to prevent UI lag

**Practical impact for Mjolnir**: If a VM produces heavy output (compilation, logs), the bridge process will buffer data on the WebSocket side. The tmux control mode throttling prevents the iTerm2 connection from being overwhelmed, but the bridge process may accumulate backpressure. The bridge should implement its own flow control or drop frames if the WebSocket backs up.

### 6.4 Control Client Detach on Empty Line

Sending an empty line (just `\n`) to the tmux control client causes it to detach. This is a protocol feature, not a bug, but it means:

- Bridge code that constructs tmux commands must never accidentally send blank lines
- Parsing code that reads from user input and forwards to tmux must filter empty lines

### 6.5 Single Control Client Limitation

While multiple clients can attach to a tmux session, only the control mode client (the one that ran `tmux -CC`) receives the structured notifications. If you need multiple control clients, you need multiple sessions or a fan-out layer.

iTerm2 expects to be the sole `-CC` consumer for a session. Running `tmux -CC attach` from two iTerm2 instances to the same session will create conflicts.

### 6.6 tmux Version Requirements

| Feature | Minimum tmux Version |
|---------|---------------------|
| Basic control mode | 1.8 |
| `-CC` (no echo) | 1.8 |
| `send-keys -H` (hex) | 2.1 |
| UTF-8 in control mode | 2.2 |
| `refresh-client -C WxH` | 2.4 |
| Format subscriptions | 3.2 |
| Extended output / flow control | 3.2 |
| `%pause` / `%continue` | 3.2 |

### 6.7 SSH Multiplexing Interaction

If the tmux session runs over SSH, consider:

- **SSH keepalives**: Without `ServerAliveInterval`, SSH may not detect a dead connection for minutes. Set `ServerAliveInterval 15` and `ServerAliveCountMax 3` in SSH config.
- **SSH multiplexing** (`ControlMaster`): Can conflict with tmux reconnection. If the SSH master connection dies, all multiplexed channels die simultaneously.
- **Mosh**: Does not support tmux -CC because Mosh does not pass through DCS sequences.

### 6.8 macOS-Specific Issues

- **App Nap**: macOS may throttle iTerm2 if it is in the background. This can cause delayed rendering of tmux output. iTerm2 has settings to disable App Nap.
- **Secure Keyboard Entry**: When enabled in iTerm2 (or by other apps like password managers), it can interfere with keyboard input routing to tmux panes.

---

## 7. Recommended Architecture for Mjolnir

### 7.1 Overview

```
+------------------+     +-------------------+     +------------------+
|                  |     |                   |     |                  |
|  iTerm2          | DCS |  tmux server      |     |  Mjolnir VMs     |
|  (macOS)         |<--->|  (local or SSH)   |     |  (cloud)         |
|                  | -CC |                   |     |                  |
|  Tab: vm-abc     |     |  Window @0: bash  | WS  |  VM abc123       |
|  Tab: vm-def     |     |  Window @1: conn  |<--->|  VM def456       |
|  Tab: vm-ghi     |     |  Window @2: conn  | WS  |  VM ghi789       |
|                  |     |  Window @3: conn  |<--->|                  |
+------------------+     +-------------------+     +------------------+
        ^                         ^
        |                         |
        |  iTerm2 Python API      |  tmux CLI
        |  (optional)             |  (socket)
        |                         |
+-------+-------------------------+--------+
|                                          |
|  MCP Tool: mjolnir_open_vm_terminal      |
|  - Creates tmux windows via CLI          |
|  - Each window runs `mjolnir connect`    |
|  - Appears as native iTerm2 tab          |
|                                          |
+------------------------------------------+
```

### 7.2 Implementation Steps

**Step 1: Ensure `mjolnir connect` works as a stdio bridge**

The connect command must work when its stdin/stdout are a PTY slave (as managed by tmux). It should:
- Set stdin to raw mode
- Forward stdin -> WebSocket, WebSocket -> stdout
- Handle SIGWINCH for resize propagation
- Implement reconnection with visible status messages
- Exit cleanly when the VM shuts down or the WebSocket closes

**Step 2: Create a tmux session bootstrap**

```bash
#!/bin/bash
# mjolnir-session.sh -- start or attach to the Mjolnir tmux session
SESSION="mjolnir"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    # Reattach in control mode
    tmux -CC attach -t "$SESSION"
else
    # Create new session in control mode
    # First window is a management shell, not a VM connection
    tmux -CC new-session -s "$SESSION" -n "mjolnir"
fi
```

**Step 3: Implement the MCP tool**

The MCP tool `mjolnir_open_vm_terminal` issues `tmux new-window` commands. Because iTerm2 is attached via `-CC`, new windows automatically appear as native tabs.

**Step 4: Handle session state**

Store active connections as tmux user options for discoverability:

```bash
# When opening a VM terminal
tmux set-option -t @${windowId} @mjolnir-vm-id "${vmId}"
tmux set-option -t @${windowId} @mjolnir-connected-at "$(date -u +%s)"

# List all VM connections
tmux list-windows -t mjolnir -F \
  '#{window_id} #{@mjolnir-vm-id} #{window_name} #{pane_pid}'
```

**Step 5: Handle cleanup**

When a VM stops or a bridge process exits, the tmux pane shows the exit status. Use tmux's `remain-on-exit` option to keep the pane visible:

```bash
tmux set-option -g remain-on-exit on
# User can then press a key to close, or the MCP tool can clean up:
tmux kill-window -t @${windowId}
```

### 7.3 Future Enhancements

1. **Format subscriptions** for real-time VM status in the tmux status bar:
   ```bash
   tmux refresh-client -B 'vm-status:@*:#{@mjolnir-vm-id} #{pane_dead}'
   ```
   This sends `%subscription-changed` notifications when VM pane state changes.

2. **Automatic VM discovery**: On `tmux -CC attach`, an MCP tool could query the Mjolnir API for the user's VMs and pre-create windows for each one.

3. **Shared monitoring pane**: A split pane showing `mjolnir status` or VM metrics alongside the interactive terminal.

4. **tmux hooks for lifecycle events**:
   ```bash
   # Run cleanup when a pane dies
   tmux set-hook -g pane-died \
     'run-shell "mjolnir cleanup-pane #{pane_id} #{@mjolnir-vm-id}"'
   ```

---

## Appendix A: Protocol Quick Reference

### Control Mode Entry
```
$ tmux -CC new -s mysession
\033P1000p                          # DCS: control mode active
%begin 1709876543 1 1               # response to implicit first command
%end 1709876543 1 1
%session-changed $0 mysession       # notification: now attached to $0
```

### Sending a Command
```
--> list-windows -F '#{window_id} #{window_name}'
<-- %begin 1709876543 2 1
<-- @0 bash
<-- @1 vim
<-- %end 1709876543 2 1
```

### Creating a Window
```
--> new-window -n mywin 'my-command arg1 arg2'
<-- %begin 1709876543 3 1
<-- %end 1709876543 3 1
<-- %window-add @2
<-- %layout-change @2 ...
<-- %output %5 $               # new pane's first output
```

### Receiving Pane Output
```
<-- %output %5 hello\040world\015\012
```

### Sending Keystrokes
```
--> send-keys -t %5 -H 6c 73 0a    # "ls\n" in hex
<-- %begin 1709876543 4 1
<-- %end 1709876543 4 1
<-- %output %5 ls\015\012
<-- %output %5 file1  file2\015\012
```

### Resizing
```
--> refresh-client -C 120x40
<-- %begin 1709876543 5 1
<-- %end 1709876543 5 1
<-- %layout-change @0 ...          # layouts recalculated
```

### Detaching
```
--> [empty line]
<-- %exit
<-- \033\\                          # DCS terminator
```

## Appendix B: Glossary

| Term | Meaning |
|------|---------|
| DCS | Device Control String -- an escape sequence envelope (`ESC P ... ESC \`) |
| Control mode | tmux mode where I/O is structured text, not terminal emulation |
| `-CC` | Double control flag: control mode with echo disabled + DCS wrapping |
| Guard | `%begin` / `%end` / `%error` markers wrapping command responses |
| Bridge process | A program that bidirectionally pipes data between a WebSocket and a PTY |
| Pane ID | tmux's `%N` identifier for a specific pane (globally unique) |
| Window ID | tmux's `@N` identifier for a window (globally unique) |
| Session ID | tmux's `$N` identifier for a session (globally unique) |
| Flow control | tmux 3.2+ mechanism to pause/resume pane output to slow clients |
