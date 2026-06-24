# VM Terminal Architecture Synthesis

**Date:** 2026-03-10
**Status:** Architecture Design (synthesized from three research tracks)
**Sources:** `pty-streaming-protocols.md`, `tmux-cc-integration.md`, `agent-terminal-patterns.md`

---

## 1. Convergences -- Where All Three Tracks Agree

The research unanimously agrees on these architectural points:

**tmux is the session primitive.** All three documents converge on tmux as the multiplexing layer inside the VM. It provides concurrent access, `capture-pane` for AI context, `send-keys` for AI input, session persistence, and window/pane management -- all battle-tested. The cost of including tmux in base images is negligible compared to reimplementing its capabilities.

**SSH over Iroh is the human transport.** `mjolnir ssh` (or `mjolnir connect`) running inside a tmux pane is the cleanest integration path. tmux manages the PTY pair; the bridge process is just a stdin/stdout-to-WebSocket/QUIC pipe. iTerm2, Ghostty, Warp, and every SSH-aware tool work without modification.

**Snapshot-based context capture for the AI.** The AI should pull terminal state on demand via `tmux capture-pane`, not receive a continuous stream. MCP is request-response; streaming adds complexity without proportional benefit. Push notifications (SSE) are reserved for discrete events like human signals.

**The VM is the shared workspace.** Both the human (via terminal) and the AI (via MCP tools) connect to the same VM. The guest agent mediates AI access. This is the Devin/Model D pattern -- the VM is the source of truth, not either participant's local machine.

**Shell function for human-to-AI signaling.** A `claude()` shell function installed in the VM's profile is the primary signaling mechanism. It captures context (last command, exit code, recent terminal output) and delivers it to the guest agent via Unix socket.

---

## 2. Tensions Resolved

### 2.1 Transport: Iroh QUIC vs WebSocket vs SSH

The PTY streaming doc presents three transports. The tmux-CC doc assumes tmux handles the terminal. The agent-patterns doc is transport-agnostic.

**Resolution: SSH over Iroh for humans, vsock for AI.**

- Human connects via `mjolnir ssh <ticket>` or `mjolnir connect <vm_id>`. Both terminate at tmux inside the VM.
- AI accesses the terminal via MCP tools, which translate to vsock calls to the guest agent, which executes tmux commands locally inside the VM.
- No WebSocket PTY bridge is needed for the shared terminal use case. The existing WebSocket path remains for the web UI.

The key insight: the human and AI use *different transports to the same tmux session*. The human attaches as a tmux client. The AI issues tmux commands via the guest agent. They never share a transport.

### 2.2 Multiplexing: tmux Inside VM vs Outside vs Both

The tmux-CC doc explores running tmux locally (on the user's Mac) with `mjolnir connect` as pane commands. The agent-patterns doc proposes tmux inside the VM. Option C in the tmux-CC doc even suggests nesting.

**Resolution: tmux inside the VM is primary. Local tmux is optional UX sugar.**

- **Inside the VM:** A tmux session is the shared workspace. The guest agent creates it. The human attaches to it. The AI operates on it via `send-keys`/`capture-pane`. This is the architectural requirement.
- **On the user's Mac:** The user *may* run tmux -CC locally (for iTerm2 native tabs across multiple VMs), but this is orthogonal. Each local tmux pane simply runs `mjolnir connect <vm_id>`, which attaches to the VM's tmux session.

No nesting conflicts arise because the local tmux just sees a raw byte stream from the bridge process -- it does not know there is tmux inside the VM.

### 2.3 MCP Tool Granularity: exec vs PTY Session vs Terminal Tools

The PTY streaming doc proposes `pty_open`/`pty_send`/`pty_read` (raw PTY session management). The agent-patterns doc proposes `terminal_open`/`terminal_read`/`terminal_send`/`terminal_send_and_read` (higher-level tmux-based tools). The PTY streaming doc also notes that `exec` is sufficient for most agent work.

**Resolution: Three tiers of MCP tools, coexisting.**

| Tier | Tools | Use Case | Mechanism |
|------|-------|----------|-----------|
| 1. Exec | `exec` | One-shot commands, no state | Subprocess in VM, capture stdout/stderr |
| 2. Terminal | `terminal_*` | Shared interactive sessions | tmux inside VM via guest agent |
| 3. PTY (future) | `pty_*` | Raw streaming for specialized agents | Direct vsock PTY channels |

Tier 2 (terminal tools) is the primary new surface. Tier 1 already exists. Tier 3 is deferred -- it adds server-side session state and buffer management that is unnecessary when tmux handles it.

### 2.4 Who Opens the iTerm2 Tab: MCP Tool vs User

The tmux-CC doc proposes an MCP tool that runs `tmux new-window` to create an iTerm2 tab. The agent-patterns doc assumes the human runs a connect command manually.

**Resolution: The MCP tool opens the tab.**

The `open_terminal` MCP tool creates a local tmux window (which becomes an iTerm2 tab via -CC) running `mjolnir connect <vm_id>`. This is the "one MCP command to full-screen terminal" experience the user wants. The tool also sets up the VM-side tmux session if it does not exist.

This requires the user to have a local tmux -CC session running. The tool detects this and provides setup instructions if not.

---

## 3. Unified Architecture

### 3.1 Layer Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  Human's Mac                                                     │
│                                                                  │
│  ┌──────────┐     ┌──────────────────────────────────────────┐   │
│  │ iTerm2   │ -CC │ Local tmux session "mjolnir"             │   │
│  │          │◄───►│                                          │   │
│  │ Tab: vm-a│     │ @0: mjolnir connect <vm-a> --session dev │   │
│  │ Tab: vm-b│     │ @1: mjolnir connect <vm-b> --session dev │   │
│  └──────────┘     └─────────────┬────────────────────────────┘   │
│                                 │ Iroh QUIC / SSH                 │
│  ┌──────────────────┐           │                                │
│  │ Claude Code      │           │                                │
│  │                  │           │                                │
│  │ MCP Client ──────┼───── MCP (stdio) ──────┐                  │
│  └──────────────────┘           │             │                  │
│                                 │             │                  │
└─────────────────────────────────┼─────────────┼──────────────────┘
                                  │             │
                            Iroh/SSH        MCP over vsock
                                  │         (via Mjolnir host)
                                  │             │
┌─────────────────────────────────┼─────────────┼──────────────────┐
│  MicroVM                        │             │                  │
│                                 ▼             ▼                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ tmux session "dev"                                       │    │
│  │                                                          │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │ Pane %0: bash (human is here)                      │  │    │
│  │  │ $ claude "help me with this error"                 │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  Human attached via SSH/Iroh ◄──┐                        │    │
│  │  AI operates via guest agent ◄──┘                        │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌───────────────────┐    ┌────────────────────┐                │
│  │ Guest Agent       │    │ Signal Socket      │                │
│  │ (Rust)            │◄───│ /run/claude/       │                │
│  │                   │    │ agent.sock         │                │
│  │ • tmux commands   │    └────────────────────┘                │
│  │ • ANSI stripping  │                                          │
│  │ • signal watch    │                                          │
│  │ • audit log       │                                          │
│  └───────────────────┘                                          │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 Transport Layer

**Human path:** `iTerm2 -> local tmux -> mjolnir connect -> Iroh QUIC / SSH -> VM sshd -> VM tmux attach`

The `mjolnir connect` command is a stdio bridge. When run inside a local tmux pane, tmux manages the PTY pair. The bridge forwards stdin/stdout to the VM over Iroh QUIC (or SSH via `mjolnir ssh`). SIGWINCH propagates resize through the full chain: iTerm2 -> local tmux -> bridge -> Iroh -> VM sshd -> VM tmux.

**AI path:** `Claude Code -> MCP tool call -> Mjolnir MCP server -> vsock -> guest agent -> tmux command -> tmux session`

No PTY involved on the AI side. The guest agent runs `tmux capture-pane` and `tmux send-keys` as subprocesses. Results return via vsock as structured data.

### 3.3 Multiplexing Layer

tmux inside the VM is the single multiplexer. It owns the shell's PTY.

- Guest agent creates the tmux session on `terminal_open`.
- Human attaches as a tmux client.
- AI operates through tmux CLI commands (via guest agent).
- Multiple panes are supported: human's main shell, AI scratch pane, monitoring panes.

Local tmux (on the Mac) is optional and independent. It manages multiple VM connections as tabs. No nesting issues because each local pane runs a bridge process, not another tmux.

### 3.4 Human UX Layer

**Full-screen native terminal via tmux -CC:**

1. User starts a local tmux -CC session: `tmux -CC new -s mjolnir`
2. iTerm2 detects the DCS `\033P1000p` and enters tmux integration mode.
3. An MCP tool creates a new window: `tmux new-window -t mjolnir -n "vm-abc" "mjolnir connect abc123 --session dev"`
4. iTerm2 renders this as a native tab labeled "vm-abc".
5. The user sees a full-screen terminal connected to the VM's tmux session.

Resize propagation is automatic through the chain described above.

**Key command to notify the AI:**

The user types `claude "message"` in the VM shell. This is a shell function (installed in the VM's `.bashrc` by the guest agent) that:
1. Captures the last 100 lines of terminal output via `tmux capture-pane`.
2. Captures the last command and its exit code.
3. Writes a JSON payload to `/run/claude/agent.sock`.
4. The guest agent forwards the signal via vsock to the Mjolnir host.
5. The MCP server delivers it as an SSE notification to Claude Code.

### 3.5 Agent Layer

Claude Code interacts via MCP tools. The tools map to tmux operations inside the VM:

| MCP Tool | tmux Operation | Purpose |
|----------|---------------|---------|
| `terminal_open` | `tmux new-session -s <name>` | Create shared session |
| `terminal_read` | `tmux capture-pane -t <pane> -p -S -N` | Read terminal state |
| `terminal_send` | `tmux send-keys -t <pane> "cmd" Enter` | Type into terminal |
| `terminal_send_and_read` | send-keys + wait for prompt + capture-pane | Run command, get output |
| `terminal_watch` | Poll capture-pane for pattern match | Wait for pattern |
| `terminal_notify` | `tmux display-message` | Show message to human |
| `terminal_signal_read` | Read from signal socket buffer | Get human's request |

The guest agent strips ANSI escape sequences before returning captured output. It performs intelligent truncation (last 3 command-output pairs in full, older content summarized, capped at ~4000 tokens).

### 3.6 Signaling Layer

**Human to AI:**
```
claude "message" -> shell function -> Unix socket -> guest agent -> vsock -> MCP notification
```

**AI to Human:**
```
terminal_notify() -> MCP tool -> vsock -> guest agent -> tmux display-message
```

**AI to Human (in-terminal):**
```
terminal_send() -> MCP tool -> vsock -> guest agent -> tmux send-keys (AI types into terminal)
```

The tmux status bar shows the AI's state:
```
set -g status-right '#{?@claude_active,#[fg=green]AI: ready,#[fg=grey]AI: off}'
```

---

## 4. MCP Tool Surface

### 4.1 Session Management

**`open_terminal`**

Opens a VM terminal as a native iTerm2 tab. This is the primary entry point.

```
Parameters:
  vm_id: string (required)        -- UUID of the target VM
  session_name: string            -- tmux session name inside VM (default: "dev")
  local_session: string           -- local tmux session to create window in (default: "mjolnir")

Behavior:
  1. Ensure VM-side tmux session exists (create via guest agent if not)
  2. Install claude() shell function in VM if not present
  3. Create local tmux window: tmux new-window -t <local_session> -n "vm-<short_id>" "mjolnir connect <vm_id> --session <session_name>"
  4. Store VM ID as tmux user option on the window

Returns:
  window_name: string             -- name of the created tab
  session_id: string              -- VM-side tmux session identifier
  status: "created" | "attached"  -- whether session was new or existing

Error:
  If no local tmux session exists, returns instructions to run: tmux -CC new -s mjolnir
```

**`terminal_list`**

```
Parameters:
  vm_id: string (required)

Returns:
  sessions: [{ session_name, pane_count, attached_clients, created_at, current_command }]
```

**`terminal_close`**

```
Parameters:
  vm_id: string (required)
  session_name: string (required)
  kill_local_window: boolean      -- also close the local tmux window (default: true)
```

### 4.2 Terminal Interaction

**`terminal_read`**

```
Parameters:
  vm_id: string (required)
  session_name: string            -- default: "dev"
  pane: string                    -- tmux pane ID (default: first pane)
  scrollback_lines: integer       -- lines of scrollback (default: 100, max: 1000)

Returns:
  content: string                 -- clean text, ANSI stripped
  rows: integer
  cols: integer
  running_command: string | null
```

**`terminal_send`**

```
Parameters:
  vm_id: string (required)
  session_name: string
  command: string                 -- complete command (Enter appended)
  OR keys: string                 -- raw tmux key sequence (e.g., "C-c", "Escape")

Returns:
  sent: boolean
```

**`terminal_send_and_read`**

```
Parameters:
  vm_id: string (required)
  session_name: string
  command: string (required)
  timeout_ms: integer             -- default: 30000
  prompt_pattern: string          -- regex for prompt (auto-detected if omitted)

Returns:
  output: string                  -- command output only (no prompt, no command echo)
  exit_code: integer | null
  duration_ms: integer
  timed_out: boolean
```

**`terminal_watch`**

```
Parameters:
  vm_id: string (required)
  session_name: string
  pattern: string (required)      -- regex to watch for
  timeout_ms: integer             -- default: 60000

Returns:
  matched: boolean
  match_text: string
  context: string                 -- surrounding lines
  elapsed_ms: integer
```

### 4.3 Signaling

**`terminal_signal_read`**

```
Parameters:
  vm_id: string (required)
  acknowledge: boolean            -- clear after reading (default: true)

Returns:
  signal: { message, context, last_command, last_exit_code, timestamp } | null
```

**`terminal_notify`**

```
Parameters:
  vm_id: string (required)
  session_name: string
  message: string (required)
  style: "info" | "success" | "warning" | "error"  -- default: "info"
```

### 4.4 MCP Notifications (Server-Initiated)

```
terminal.signal_received    -- human used claude() function
terminal.command_completed  -- a watched command finished
terminal.error_detected     -- error pattern appeared in output
terminal.session_ended      -- tmux session was destroyed
```

---

## 5. End-to-End Design: MCP Command to Full-Screen Terminal

This is the complete flow for the user's original request.

### Prerequisites

The user has:
- iTerm2 open
- A local tmux -CC session running: `tmux -CC new -s mjolnir`
- Claude Code running with the Mjolnir MCP server configured

### Step-by-Step

**1. User asks Claude Code:**
> "Open a terminal to my VM abc123"

**2. Claude Code calls `open_terminal`:**
```json
{ "vm_id": "abc123", "session_name": "dev" }
```

**3. MCP server (via vsock to guest agent):**
- Creates tmux session "dev" inside VM abc123 if it does not exist
- Installs `claude()` shell function in `.bashrc` if not present
- Returns session info

**4. MCP server (local tmux command):**
```bash
tmux new-window -t mjolnir -n "vm-abc123" "mjolnir connect abc123 --session dev"
tmux set-option -t @<window_id> @mjolnir-vm-id "abc123"
```

**5. iTerm2 creates a native tab** labeled "vm-abc123". The user sees a full-screen shell.

**6. User works normally.** Types commands, runs programs. Full-screen terminal experience.

**7. User wants AI help:**
```bash
$ claude "the tests are failing, can you look?"
```

**8. Signal delivery:**
- Shell function captures last 100 lines + last command + exit code
- Writes JSON to `/run/claude/agent.sock`
- Guest agent forwards via vsock
- MCP server emits `terminal.signal_received` notification

**9. Claude Code receives notification, calls `terminal_read`:**
- Gets clean terminal content (ANSI stripped)
- Analyzes the test failure

**10. Claude Code responds:**
- Calls `terminal_notify(vm_id, "Found the issue -- the mock in auth.test.ts returns undefined. Fixing now.")`
- User sees the message in tmux status bar
- Claude Code calls `terminal_send(vm_id, command="sed -i 's/undefined/mockUser/' tests/auth.test.ts")`
- Claude Code calls `terminal_send_and_read(vm_id, command="npm test")`
- Tests pass
- Claude Code calls `terminal_notify(vm_id, "Fixed. All tests passing now.", style="success")`

**11. User sees the fix happen in real-time** (the commands appear in their terminal) and the success notification.

---

## 6. Implementation Phases

### Phase 1: Shared Terminal Foundation (2 weeks)

**Goal:** AI can read and write to a terminal session that the human is also using.

Build:
- Guest agent: tmux session management (create, list, destroy)
- Guest agent: `capture-pane` with ANSI stripping (use `strip-ansi-escapes` crate)
- Guest agent: `send-keys` dispatch
- Guest agent: prompt detection for `send_and_read` (look for PS1 pattern or OSC 133 markers)
- Vsock message types: `terminal_open`, `terminal_read`, `terminal_send`, `terminal_send_and_read`, `terminal_list`, `terminal_close`
- MCP server: new tool handlers that proxy to vsock
- `mjolnir connect`: `--session <name>` flag to attach to a named tmux session

**Exit criteria:** Claude Code can run `terminal_open`, `terminal_send_and_read("ls -la")`, and `terminal_read` against a VM. Human can attach to the same session via `mjolnir connect --session dev` and see the AI's commands.

### Phase 2: Native Tab + Signaling (2 weeks)

**Goal:** One MCP command opens a full-screen iTerm2 tab. Human can signal the AI.

Build:
- MCP tool: `open_terminal` (creates local tmux window + VM-side session)
- `claude()` shell function (auto-installed in VM profile)
- Guest agent: Unix socket watcher for signals
- Vsock message type: `signal_received`
- MCP notification: `terminal.signal_received`
- MCP tools: `terminal_signal_read`, `terminal_notify`
- Guest agent: tmux status bar configuration (AI state indicator)
- `terminal_watch` tool (poll-based pattern matching on capture-pane)
- Shell integration markers (OSC 133) in VM base image for reliable prompt detection

**Exit criteria:** User says "open a terminal to VM X", gets an iTerm2 tab. User types `claude "help"`, Claude Code receives the signal with context and responds.

### Phase 3: Safety + Polish (2 weeks)

Build:
- Credential detection and redaction in captured output
- Private mode: `claude --private` / `claude --resume`
- Command audit log (all AI-initiated commands logged with timestamps)
- Intelligent context truncation (prompt-boundary-aware, error-focused)
- Reconnection handling in `mjolnir connect` (exponential backoff, visible status)
- tmux `remain-on-exit` for dead pane visibility
- Window cleanup on VM stop
- tmux user options for VM metadata (`@mjolnir-vm-id`, `@mjolnir-connected-at`)

**Exit criteria:** Production-quality shared terminal with credential safety and audit trail.

### Phase 4: Advanced (Future)

- Multi-pane management (AI opens scratch panes for background work)
- Multi-VM terminal orchestration
- PTY output ring buffer in guest agent (reconnection replay)
- Session recording and replay
- WebRTC data channel for real-time terminal streaming (if snapshot model proves insufficient)
- Proactive error detection (guest agent watches for error patterns, notifies AI without human signal)

---

## 7. Open Questions

### 7.1 Local tmux -CC Bootstrapping

The `open_terminal` tool requires a local tmux -CC session. Options:
- **A. Require the user to start it manually.** Simple but adds a prerequisite step.
- **B. The MCP tool starts it.** Difficult -- `tmux -CC` must run inside iTerm2, and MCP tools run in a subprocess.
- **C. Detect and guide.** The tool checks for a local tmux session and returns clear instructions if missing.

**Leaning toward C.** First-time setup instructions, then seamless afterward.

### 7.2 tmux Version in VM Images

tmux >= 3.2 is needed for flow control and extended output. The VM base image must include a recent enough version. Alpine's package repos may lag. May need to build from source or use Ubuntu-based images.

### 7.3 Prompt Detection Reliability

`terminal_send_and_read` needs to know when a command finishes. Options:
- **PS1 pattern matching:** Fragile across different shells and configurations.
- **OSC 133 markers:** Reliable but requires shell integration in the VM. Recommended.
- **Unique sentinel:** Wrap commands in `echo __START__; cmd; echo __END__`. Reliable but ugly if the human is watching.

**Recommendation:** Use OSC 133 as primary (installed by guest agent). Fall back to PS1 pattern matching. Accept that some edge cases (commands that change PS1) will be unreliable.

### 7.4 MCP Notification Delivery

Claude Code's MCP client must support server-initiated notifications for the signal flow to work without polling. If not supported, the fallback is:
- Claude Code periodically calls `terminal_signal_read` in a polling loop.
- Or the user explicitly asks Claude Code to check for signals.

This is a Claude Code platform question, not an architecture question.

### 7.5 Multi-Agent Coordination

If multiple Claude Code instances (or other AI agents) access the same VM, they need separate tmux sessions or explicit coordination. The recommended pattern is separate sessions per agent, with a shared "monitoring" window for cross-visibility. This is deferred to Phase 4.

### 7.6 Guest Agent Scope Creep

The guest agent is gaining responsibilities: exec, PTY management, tmux orchestration, signal watching, ANSI stripping, credential detection, audit logging. Consider whether these should be a separate binary (e.g., `mjolnir-terminal-agent`) that the guest agent spawns, keeping the core guest agent focused on vsock communication.

---

## References

- `docs/research/pty-streaming-protocols.md` -- Transport analysis, MCP PTY tool design, SSH recommendation
- `docs/research/tmux-cc-integration.md` -- tmux -CC protocol, iTerm2 integration, resize chain, session persistence
- `docs/research/agent-terminal-patterns.md` -- Sharing patterns, signaling mechanisms, MCP tool design, security, roadmap
- `mjolnir_protocol/src/lib.rs` -- Binary wire protocol (Data/Resize/Exit/Hello frames)
- `mjolnir_guest_agent/src/vsock.rs` -- Vsock listener, PTY channel multiplexing
- `mjolnir_client/src/connect.rs` -- Client-side Iroh QUIC + WebSocket bridge
- `mjolnir_client/src/mcp.rs` -- Existing MCP tools (exec, await_pty, spawn_vm)
