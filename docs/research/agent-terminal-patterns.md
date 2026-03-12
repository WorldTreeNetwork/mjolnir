# Human-AI Shared Terminal Sessions: Patterns, Mechanisms, and Mjolnir Design

**Status:** Research Document
**Date:** 2026-03-10
**Context:** Mjolnir microVM platform with MCP tools for Claude Code

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Human-AI Terminal Sharing Patterns](#2-human-ai-terminal-sharing-patterns)
3. [Agent Terminal Interaction Patterns](#3-agent-terminal-interaction-patterns)
4. [Signaling Mechanisms](#4-signaling-mechanisms)
5. [Context Capture Techniques](#5-context-capture-techniques)
6. [MCP Tool Design](#6-mcp-tool-design)
7. [Security Considerations](#7-security-considerations)
8. [Recommended Architecture for Mjolnir](#8-recommended-architecture-for-mjolnir)
9. [Implementation Roadmap](#9-implementation-roadmap)
10. [Open Questions and Trade-offs](#10-open-questions-and-trade-offs)

---

## 1. Problem Statement

The goal is a terminal session where a human and an AI agent can both participate -- the human working in their iTerm2 full-screen, the AI agent (Claude Code via MCP tools) able to observe output, send commands, and respond to the human's requests for help. This is fundamentally different from the current `exec` model, where the agent fires a command and gets back stdout/stderr. What we want is a *persistent, shared, stateful terminal session* with fluid control transfer.

The core tension: terminals are designed for a single operator. Adding a second participant (especially a non-human one) requires solving multiplexing, signaling, context sharing, and control arbitration -- without breaking the terminal's interactive nature.

---

## 2. Human-AI Terminal Sharing Patterns

### 2.1 Prior Art: Human-Human Terminal Sharing

Several tools have solved the "two humans, one terminal" problem. Their design choices are instructive.

**tmux / screen (session sharing)**

tmux is the most mature terminal multiplexer. Two sharing modes exist:

- **Socket sharing:** Multiple tmux clients attach to the same tmux server socket. Both see the same content, both can type. No arbitration -- keystrokes from either client are interleaved. This works for pair programming because humans coordinate verbally.
- **Read-only attach:** `tmux attach -r` gives an observer a live view without input ability. Useful for demos and monitoring.

Key properties: the tmux server is the single source of truth. It owns the PTY. Clients are thin renderers. The shared state is the terminal buffer itself.

**tmate (remote tmux sharing)**

tmate is a tmux fork that adds SSH-based remote access. It generates a unique SSH URL that a remote participant uses to attach. Two URL types:
- Read-write: full control
- Read-only: observation only

Architecture: tmate runs a relay server. The host's tmux session connects to the relay via SSH. Remote participants SSH into the relay. The relay multiplexes input/output. This is essentially tmux socket sharing over SSH tunnels.

Relevance to Mjolnir: tmate proves that terminal sharing over a network relay works well. The relay model maps to our signaling server or Mjolnir host.

**VS Code Live Share (terminal sharing)**

VS Code Live Share exposes a "shared terminal" feature where the host can share a terminal with guests. Key design decisions:

- Terminals are explicitly shared (opt-in per terminal)
- Guests can be read-only or read-write
- The host sees a visual indicator when a guest is typing
- Terminal output is streamed via the Live Share relay, not peer-to-peer
- The host can revoke terminal access at any time

Relevance: The explicit opt-in and visual indicators are good UX patterns. The "host decides what to share" model maps well to our use case (human decides when AI can see/interact with the terminal).

**Tuple (pair programming)**

Tuple is a macOS pair programming app. Its terminal sharing is screen-share based -- the remote participant sees the host's screen and can take control of keyboard/mouse. This is a different paradigm (pixel sharing, not character sharing) but introduces an important pattern: **control handoff**. Either participant can "take the wheel" with a clear visual signal of who is driving.

**Teleconsole (now defunct)**

Teleconsole used Gravitational Teleport to create SSH-accessible terminal sessions. Notable for its simplicity: run `teleconsole` and you get a URL anyone can SSH into. The session was a shared PTY with both parties able to type.

### 2.2 Patterns That Transfer to Human-AI

From the above, several patterns apply to human-AI terminal sharing:

| Pattern | Source | Application |
|---|---|---|
| Single PTY, multiple consumers | tmux | One terminal session, human and AI both connected |
| Read-only vs read-write modes | tmate, VS Code | AI can observe (read-only) or actively type (read-write) |
| Explicit sharing (opt-in) | VS Code Live Share | Human explicitly invites AI to the session |
| Control handoff signal | Tuple | Human says "take over" / AI says "handing back" |
| Relay-based transport | tmate, VS Code | Terminal data flows through Mjolnir host, not direct |
| Visual indicator of who is driving | Tuple, VS Code | Prompt decoration or status line shows current operator |

### 2.3 What Is Different About Human-AI

Human-human terminal sharing assumes both participants can read the terminal at the same rate and understand visual context (cursor position, colors, layout). An AI agent is fundamentally different:

- **No persistent visual state:** The AI does not "see" the terminal continuously. It samples the terminal buffer at discrete moments (when a tool is called). Between samples, the terminal state may change arbitrarily.
- **ANSI is noise:** Raw terminal output includes escape sequences for color, cursor movement, line wrapping, etc. The AI needs semantic content, not rendering instructions. ANSI must be stripped or parsed.
- **No peripheral vision:** A human notices a background job finishing (new line appears), a compilation error scrolling by, or a prompt changing. The AI only knows what it explicitly reads.
- **Latency asymmetry:** The human types at ~80 WPM with instant feedback. The AI's "typing" is a tool call that takes seconds to round-trip through MCP. The AI cannot do interactive things like respond to `[y/n]` prompts in real-time without a specialized mechanism.
- **Context window limits:** The AI can only process a bounded amount of terminal output per interaction. A 10,000-line build log needs summarization, not raw capture.

These differences mean we cannot simply give the AI a tmux client. We need a mediation layer that:
1. Captures terminal state in AI-digestible form
2. Allows the AI to inject input at appropriate moments
3. Provides signaling for control transfer
4. Handles the asynchronous nature of AI responses

---

## 3. Agent Terminal Interaction Patterns

### 3.1 Current State of the Art

**Claude Code (Anthropic)**

Claude Code uses a `Bash` tool that executes commands in a subprocess. Each invocation is independent -- it spawns a shell, runs the command, captures stdout/stderr, and returns. There is no persistent shell session. Environment variables and working directory are reset between calls (with some workarounds). This is the "exec" model: fire-and-forget with captured output.

Limitations: Cannot interact with long-running processes, cannot handle interactive prompts, cannot maintain shell state (aliases, environment, shell functions), cannot observe output from commands the human runs.

Claude Code also supports `run_in_background` for long-running commands, with a `TaskOutput` tool to read results later. This is closer to a persistent session but still non-interactive.

**Cursor**

Cursor's terminal integration runs commands in the user's existing VS Code terminal. The AI types into the terminal and observes output. Key difference from Claude Code: the terminal is persistent, so shell state (cd, export, aliases) carries across commands. Cursor uses VS Code's terminal API which provides programmatic access to the terminal buffer.

**Copilot Workspace (GitHub)**

Copilot Workspace uses a "workspace" model where the AI operates in a cloud environment. Terminal interaction is through a web-based terminal (xterm.js). The AI can run commands and read output, but sharing with a human is limited to the web UI.

**Devin (Cognition)**

Devin runs in a cloud VM with a full desktop environment. It has its own terminal emulator and browser. The human observes via a web UI that shows Devin's screen. The human can "take over" by clicking into the browser/terminal view. This is the most immersive human-AI sharing model in production, but it is screen-share based (pixels, not characters).

Key insight from Devin: the *workspace is the VM*. The AI operates inside the VM, not outside it. The human connects to the same VM to observe and intervene. This maps directly to Mjolnir's model.

**SWE-agent (Princeton NLP)**

SWE-agent uses a custom shell wrapper that intercepts commands, manages history, and constrains the AI's actions. The shell wrapper is a Python script that:
- Presents a simplified interface to the AI (custom commands like `edit`, `search`)
- Captures all output with ANSI stripping
- Manages a "window" into files (pagination)
- Enforces guardrails (prevents rm -rf, etc.)

This is an example of a *mediated terminal* -- the AI does not interact with a raw terminal but with a structured overlay that translates between AI-friendly operations and actual shell commands.

**Aider**

Aider runs in the user's terminal and uses the user's shell for command execution. It asks the user for permission before running commands. The interaction model is conversational: the AI proposes commands, the human approves, and Aider executes them in a subprocess. This is a "human-in-the-loop" pattern where the human retains control.

### 3.2 Taxonomy of Agent-Terminal Interaction Models

From the above, four distinct models emerge:

**Model A: Exec (Fire-and-Forget)**
```
Agent --[command]--> subprocess --[stdout/stderr]--> Agent
```
- Used by: Claude Code `Bash` tool, current Mjolnir `exec` MCP tool
- Pros: Simple, stateless, safe (each command is isolated)
- Cons: No persistent state, no interactivity, no human sharing

**Model B: Persistent Shell (Agent-Owned)**
```
Agent --[commands]--> persistent shell --[output stream]--> Agent
                           |
                     (human cannot see)
```
- Used by: SWE-agent, some Copilot Workspace flows
- Pros: Shell state persists, can chain commands
- Cons: Human is locked out, no sharing

**Model C: Shared Terminal (Human Primary)**
```
Human <--> terminal <--[observe/inject]--> Agent
```
- Used by: Cursor (partially), Aider (with permission)
- Pros: Human retains control, AI assists
- Cons: Agent is a second-class citizen, asynchronous conflicts

**Model D: Shared Workspace (VM-Centric)**
```
Human --[connect]--> VM terminal <--[connect]--> Agent
```
- Used by: Devin, Gitpod with AI
- Pros: Both participants have full access, VM is the shared state
- Cons: Requires VM infrastructure, more complex

**Mjolnir should implement Model D**, with elements of Model C for the control-transfer UX. The VM is the natural shared workspace. Both the human (via iTerm2 + SSH/Iroh) and the AI agent (via MCP tools) connect to the same VM. The terminal multiplexer inside the VM (tmux) provides the shared session primitive.

---

## 4. Signaling Mechanisms

The most important UX challenge: how does the human tell the AI "look at this" or "take over," and how does the AI tell the human "I'm done, back to you"?

### 4.1 In-Band Signaling (Within the Terminal)

**Magic comments / sentinel strings**

The simplest approach: the human types a special string that the AI recognizes.

```bash
# @claude look at this error
# @claude take over and fix the build
# @claude what does this output mean?
```

Implementation: A watcher process monitors the terminal output (via tmux `capture-pane` or a pipe) for lines matching a pattern like `# @claude ...` or `@ai ...`. When detected, it extracts the message and delivers it to the AI via MCP.

Pros:
- Zero setup, works in any terminal
- Human types naturally
- The request and its context (surrounding terminal output) are co-located
- Works over SSH, Iroh, any transport

Cons:
- Pollutes the terminal history / shell history
- Requires a background watcher process
- Cannot signal without typing (e.g., cannot signal from within vim)
- May trigger accidentally if someone types the sentinel in code

**Shell function / alias**

A shell function provides a cleaner interface:

```bash
claude() {
    echo "__CLAUDE_REQUEST__${*}__END__" > /tmp/claude-signal
    # OR: write to a named pipe / Unix socket
}

# Usage:
claude "look at the output of the last command"
claude "take over and install the dependencies"
```

Pros:
- Clean UX, feels like a natural command
- Can capture context (previous command output via `$?`, `!!`, etc.)
- Does not pollute normal output
- Can include structured metadata

Cons:
- Requires setup (function must be loaded in shell)
- Only works in shell (not in vim, less, etc.)

**Enhanced shell function with context capture:**

```bash
claude() {
    local last_exit=$?
    local last_cmd=$(fc -ln -1)
    local pane_content=$(tmux capture-pane -p -S -50)

    cat > /tmp/claude-signal <<EOF
{
  "message": "$*",
  "last_command": "$last_cmd",
  "last_exit_code": $last_exit,
  "terminal_context": $(echo "$pane_content" | jq -Rs .)
}
EOF
    # Signal the watcher
    kill -USR1 $(cat /tmp/claude-watcher.pid) 2>/dev/null
}
```

This is the recommended approach for Mjolnir -- it captures rich context and signals efficiently.

### 4.2 Out-of-Band Signaling (Outside the Terminal)

**File watcher (inotify/FSEvents)**

A designated file or directory is watched for changes. Writing to the file signals the AI.

```bash
echo "help me debug this" > ~/.claude/signal
```

The Mjolnir guest agent watches `~/.claude/signal` (or a similar path) and forwards the content to the MCP server when it changes.

Pros:
- Works from any context (shell, vim, script, GUI app)
- Can include arbitrary structured data
- Simple to implement (inotify on Linux, FSEvents on macOS)

Cons:
- Requires knowing the file path
- File-based signaling has race conditions (partial writes)
- Feels less natural than typing a command

**Named pipe (FIFO)**

```bash
mkfifo /tmp/claude-pipe
# Writer (human):
echo "take over" > /tmp/claude-pipe
# Reader (watcher):
while read line < /tmp/claude-pipe; do handle_signal "$line"; done
```

Pros:
- No polling, blocks until data arrives
- No file cleanup needed
- Atomic message delivery

Cons:
- Blocks the writer until the reader consumes
- One message at a time
- Less portable than files

**Unix domain socket**

A local socket provides bidirectional communication between the human's shell and the AI watcher:

```bash
# In shell (using socat or nc):
echo '{"action":"help","context":"build failing"}' | socat - UNIX-CONNECT:/tmp/claude.sock
```

Pros:
- Bidirectional (AI can send responses back)
- Non-blocking
- Can handle multiple concurrent signals
- Structured protocol possible

Cons:
- Requires socat or custom client
- More complex setup

### 4.3 Terminal-Native Signaling

**iTerm2 proprietary escape sequences**

iTerm2 supports custom escape sequences that trigger actions:

```bash
# Set a user variable (visible to iTerm2 triggers):
printf "\033]1337;SetUserVar=%s=%s\007" "claude_signal" "$(echo -n 'help' | base64)"

# Trigger a custom action via iTerm2's "SetMark" / triggers:
printf "\033]1337;SetMark\007"
```

iTerm2 triggers can match regex patterns in terminal output and execute actions (run a script, send a notification, highlight text). A trigger could watch for `@claude` and run a script that signals the AI.

Pros:
- Deep iTerm2 integration
- Can trigger without typing (programmatically)
- iTerm2 triggers can highlight the request visually

Cons:
- iTerm2-specific (not portable to other terminals)
- Escape sequences are fragile in nested sessions (SSH + tmux)
- Limited payload in escape sequences

**OSC 52 (clipboard integration)**

OSC 52 is a standard escape sequence for clipboard manipulation. It could be repurposed for signaling:

```bash
# Copy to clipboard AND signal the AI:
printf "\033]52;c;%s\007" "$(echo -n '@claude: help' | base64)"
```

This is a hack and not recommended -- it conflicts with legitimate clipboard usage.

**Terminal bell / notification**

```bash
# BEL character:
printf "\a"
```

Too coarse -- no payload, cannot distinguish between "signal the AI" and "command finished."

### 4.4 OS-Level Signaling

**Unix signals (SIGUSR1/SIGUSR2)**

A process can send a signal to the AI watcher:

```bash
kill -USR1 $(cat /tmp/claude-watcher.pid)
```

Pros:
- Instantaneous delivery
- Lightweight

Cons:
- No payload (signal only carries "something happened")
- Must be combined with another mechanism for the actual message
- PID management is fragile

**D-Bus / XPC (desktop IPC)**

On Linux (D-Bus) or macOS (XPC), desktop IPC can signal between the terminal and an AI agent. Not practical for VM-based workflows.

### 4.5 Recommended Signaling Stack for Mjolnir

A layered approach, from simplest to most integrated:

**Layer 1 (Minimum Viable): Shell function + file signal**

```bash
# Installed in VM's .bashrc / .zshrc by guest agent
claude() {
    local context=$(tmux capture-pane -p -S -100 2>/dev/null || echo "no tmux")
    local payload=$(jq -n \
        --arg msg "$*" \
        --arg ctx "$context" \
        --arg cmd "$(fc -ln -1 2>/dev/null)" \
        --argjson exit "${PIPESTATUS[-1]:-$?}" \
        '{message: $msg, context: $ctx, last_command: $cmd, last_exit_code: $exit}')
    echo "$payload" > /run/claude/signal
}
```

The guest agent watches `/run/claude/signal` via inotify and forwards to the MCP server.

**Layer 2 (Better): Unix socket with bidirectional communication**

```bash
# Shell function sends to guest agent's socket:
claude() {
    local payload=... # same as above
    echo "$payload" | socat - UNIX-CONNECT:/run/claude/agent.sock
}

# Guest agent listens on the socket, forwards via vsock to host,
# host delivers via MCP notification to Claude Code.
```

**Layer 3 (Best): Integrated tmux plugin + guest agent protocol**

A tmux status bar shows the AI's state (idle/thinking/typing). The tmux plugin intercepts a keybinding (e.g., `prefix + @`) to open a prompt for messaging the AI. The plugin communicates with the guest agent via socket.

```
# tmux.conf (loaded by guest agent on session setup):
set -g status-right '#{?claude_active,#[fg=green]AI: ready,#[fg=grey]AI: off}'
bind @ command-prompt -p "Ask Claude:" "run-shell 'claude %%'"
```

---

## 5. Context Capture Techniques

When the AI is asked to "look at this," it needs the terminal's current state. Several capture methods exist, each with trade-offs.

### 5.1 tmux capture-pane

```bash
# Capture visible pane content:
tmux capture-pane -p

# Capture with scrollback (last 500 lines):
tmux capture-pane -p -S -500

# Capture with escape sequences (preserves colors):
tmux capture-pane -p -e

# Capture to a buffer and save:
tmux capture-pane -b capture_buffer
tmux save-buffer -b capture_buffer /tmp/terminal-capture.txt
```

Pros:
- Most reliable method for terminal content
- Can capture scrollback history
- Works regardless of what program is running (vim, less, top, etc.)
- Can capture with or without ANSI escape sequences
- tmux is the standard for server-side terminal multiplexing

Cons:
- Requires tmux (must be part of the VM session setup)
- Capture is a point-in-time snapshot (not streaming)
- Does not capture semantic structure (which lines are prompts, which are output)
- ANSI stripping is lossy (color information may be meaningful)

**This is the recommended primary capture method for Mjolnir.**

### 5.2 script / typescript

The `script` command records a terminal session to a file:

```bash
script -q /tmp/session.log
# All terminal I/O is recorded to session.log
```

Pros:
- Captures everything (input and output)
- Continuous recording (not point-in-time)
- Standard Unix tool, available everywhere

Cons:
- Raw recording includes ANSI escapes, timing artifacts
- File grows unboundedly (needs rotation)
- Replaying requires `scriptreplay` (not just reading the file)
- Hard to extract "the last N lines of meaningful output"

### 5.3 Terminal Buffer via pty

The guest agent can create a PTY pair and sit between the user's connection and the actual shell:

```
User's SSH/Iroh connection
    |
    v
Guest Agent (PTY master) <--- reads all I/O
    |
    v
Shell (PTY slave)
```

This "man-in-the-middle" approach gives the guest agent access to all terminal I/O in real-time.

Pros:
- Full I/O capture without tmux dependency
- Can inject input (AI "types" into the PTY master)
- Can implement input filtering / guardrails
- Real-time streaming possible

Cons:
- Complex to implement correctly (PTY handling, signal forwarding, window resize)
- Adds latency
- Must handle binary data, escape sequences, and character encoding
- Must be transparent -- the user should not notice the intermediary

### 5.4 ANSI Parsing and Semantic Extraction

Raw terminal output contains ANSI escape sequences:

```
\033[32muser@vm\033[0m:\033[34m~/project\033[0m$ make
\033[31merror:\033[0m undefined reference to `main'
```

For AI consumption, this should be parsed into:
```
user@vm:~/project$ make
error: undefined reference to `main'
```

Options for ANSI stripping/parsing:

- **Simple strip:** `sed 's/\x1b\[[0-9;]*m//g'` -- removes color codes but not cursor movement
- **Full parse:** Use a terminal emulator library (like `vt100` crate in Rust, or `ansi_up` in JS) that maintains a virtual terminal buffer and outputs clean text
- **Selective preserve:** Strip colors but keep structure (newlines, tabs). This is usually what the AI needs.

The guest agent should perform ANSI parsing before sending context to the AI. The AI does not benefit from raw escape sequences.

### 5.5 Intelligent Truncation

Terminal captures can be large. The AI's context window is finite. Strategies for truncation:

- **Last N lines:** Simple but may miss the start of a relevant block (e.g., the command that produced the output).
- **Last N commands:** Parse the capture for prompt patterns and extract the last N command-output pairs. More semantic, requires knowing the prompt format.
- **Error-focused:** Scan for error patterns (exit codes != 0, "error:", "failed", "exception") and include surrounding context.
- **Smart windowing:** Include the last command-output pair in full, plus the last 20 lines of scrollback, plus any lines containing error patterns from the full capture.

Recommended approach for Mjolnir:

```
1. Capture last 500 lines via tmux capture-pane
2. Strip ANSI escape sequences
3. Identify prompt boundaries (using PS1 pattern)
4. Extract last 3 command-output pairs in full
5. Summarize anything older as "N earlier commands..."
6. Total output capped at ~4000 tokens
```

### 5.6 Streaming vs Snapshot

Two modes of terminal context capture:

**Snapshot (pull-based):** Capture the terminal state when the AI needs it (when a tool is called, when the human signals). This is simpler, fits the MCP request-response model, and avoids overwhelming the AI with continuous data.

**Streaming (push-based):** Continuously stream terminal output to the AI. Problematic because:
- The AI cannot process a continuous stream (it operates in request-response turns)
- Bandwidth waste when the AI is not actively engaged
- MCP does not have a natural "subscribe to terminal output" primitive (though SSE notifications could be adapted)

**Recommendation:** Use snapshot-based capture as the primary model. Add a "watch mode" where the guest agent buffers recent output and can provide a summary on demand ("what happened in the last 30 seconds?"). Streaming is only valuable for specific use cases like real-time log monitoring, which can be modeled as a long-running MCP tool call with SSE output.

---

## 6. MCP Tool Design

### 6.1 Core Terminal Tools

Building on Mjolnir's existing MCP tools (particularly `exec` and `await_pty`), here is a proposed tool set for shared terminal interaction:

**`terminal_open`** -- Create or attach to a terminal session in a VM

```json
{
  "name": "terminal_open",
  "description": "Open a persistent terminal session in a VM. Creates a tmux session that both the human and AI can access. Returns a session ID and connection instructions for the human.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string", "description": "UUID of the target VM" },
      "session_name": { "type": "string", "description": "Name for the tmux session (default: 'shared')" },
      "shell": { "type": "string", "description": "Shell to use (default: user's login shell)" },
      "working_directory": { "type": "string", "description": "Initial working directory" }
    },
    "required": ["vm_id"]
  },
  "output": {
    "session_id": "string (tmux session:window.pane identifier)",
    "connection_command": "string (command the human runs to attach, e.g., 'mjolnir connect <vm_id> --session shared')",
    "status": "created | attached"
  }
}
```

**`terminal_read`** -- Read current terminal state

```json
{
  "name": "terminal_read",
  "description": "Capture the current visible content of a terminal session, plus recent scrollback. Returns clean text with ANSI escape sequences stripped.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string", "description": "tmux session ID (from terminal_open)" },
      "scrollback_lines": { "type": "integer", "description": "Number of scrollback lines to include (default: 100, max: 1000)" },
      "include_ansi": { "type": "boolean", "description": "Include ANSI escape sequences (default: false)" }
    },
    "required": ["vm_id"]
  },
  "output": {
    "content": "string (terminal text)",
    "rows": "integer (terminal height)",
    "cols": "integer (terminal width)",
    "cursor_row": "integer",
    "cursor_col": "integer",
    "running_command": "string | null (currently executing command, if detectable)"
  }
}
```

**`terminal_send`** -- Send input to the terminal

```json
{
  "name": "terminal_send",
  "description": "Send keystrokes or a command to the terminal session. The input is typed into the terminal as if a user typed it. Use 'command' for complete commands (appends Enter), or 'keys' for raw keystroke sequences.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string" },
      "command": { "type": "string", "description": "Command to execute (Enter is appended automatically)" },
      "keys": { "type": "string", "description": "Raw tmux key sequence (e.g., 'C-c' for Ctrl+C, 'Escape' for ESC)" },
      "delay_ms": { "type": "integer", "description": "Delay between keystrokes in ms (for interactive programs, default: 0)" }
    },
    "required": ["vm_id"],
    "oneOf": [
      { "required": ["command"] },
      { "required": ["keys"] }
    ]
  },
  "output": {
    "sent": "boolean",
    "echo": "string (terminal content captured ~100ms after sending, for quick feedback)"
  }
}
```

**`terminal_send_and_read`** -- Send a command and wait for output

```json
{
  "name": "terminal_send_and_read",
  "description": "Send a command and wait for it to complete, then capture the output. More reliable than terminal_send + terminal_read for non-interactive commands. Waits for the shell prompt to reappear as the completion signal.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string" },
      "command": { "type": "string" },
      "timeout_ms": { "type": "integer", "description": "Max wait time (default: 30000)" },
      "prompt_pattern": { "type": "string", "description": "Regex for the shell prompt (auto-detected if not specified)" }
    },
    "required": ["vm_id", "command"]
  },
  "output": {
    "output": "string (command output, excluding the command itself and the final prompt)",
    "exit_code": "integer | null (if detectable)",
    "duration_ms": "integer",
    "timed_out": "boolean"
  }
}
```

**`terminal_watch`** -- Watch for patterns in terminal output

```json
{
  "name": "terminal_watch",
  "description": "Watch the terminal for a specific pattern and return when it appears. Useful for waiting for build completion, server startup, etc.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string" },
      "pattern": { "type": "string", "description": "Regex pattern to watch for" },
      "timeout_ms": { "type": "integer", "description": "Max wait time (default: 60000)" },
      "capture_lines": { "type": "integer", "description": "Number of lines around the match to capture (default: 10)" }
    },
    "required": ["vm_id", "pattern"]
  },
  "output": {
    "matched": "boolean",
    "match_text": "string (the matched line)",
    "context": "string (surrounding lines)",
    "elapsed_ms": "integer"
  }
}
```

**`terminal_list`** -- List active terminal sessions

```json
{
  "name": "terminal_list",
  "description": "List all active terminal sessions in a VM.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" }
    },
    "required": ["vm_id"]
  },
  "output": {
    "sessions": [
      {
        "session_id": "string",
        "session_name": "string",
        "created_at": "string (ISO 8601)",
        "attached_clients": "integer",
        "size": "string (e.g., '200x50')",
        "current_command": "string | null"
      }
    ]
  }
}
```

**`terminal_close`** -- Close a terminal session

```json
{
  "name": "terminal_close",
  "description": "Close a terminal session. Sends SIGHUP to the shell and destroys the tmux session.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string" }
    },
    "required": ["vm_id", "session_id"]
  }
}
```

### 6.2 Signaling Tools

**`terminal_signal_read`** -- Read pending signals from the human

```json
{
  "name": "terminal_signal_read",
  "description": "Read any pending signals/requests from the human in the terminal. The human uses the `claude` shell function to send these. Returns null if no pending signals.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "acknowledge": { "type": "boolean", "description": "Clear the signal after reading (default: true)" }
    },
    "required": ["vm_id"]
  },
  "output": {
    "signal": {
      "message": "string",
      "context": "string (terminal content at time of signal)",
      "last_command": "string",
      "last_exit_code": "integer",
      "timestamp": "string (ISO 8601)"
    }
  }
}
```

**`terminal_notify`** -- Send a notification to the human in the terminal

```json
{
  "name": "terminal_notify",
  "description": "Display a notification to the human in the terminal. Uses tmux display-message or writes to a status line.",
  "input_schema": {
    "type": "object",
    "properties": {
      "vm_id": { "type": "string" },
      "session_id": { "type": "string" },
      "message": { "type": "string", "description": "Message to display" },
      "style": { "type": "string", "enum": ["info", "success", "warning", "error"], "description": "Visual style (default: info)" },
      "duration_seconds": { "type": "integer", "description": "How long to show the message (default: 5)" }
    },
    "required": ["vm_id", "message"]
  }
}
```

### 6.3 The `exec` Tool vs Terminal Tools

The existing `exec` tool remains valuable for one-shot commands where the AI does not need a shared session. The terminal tools are for interactive, persistent, shared sessions. The two models coexist:

| Use Case | Tool | Why |
|---|---|---|
| Run a quick command, get output | `exec` | Simple, stateless, fast |
| Work in a shared session with the human | `terminal_*` | Persistent, interactive, shared |
| Long-running build, watch for completion | `terminal_send_and_read` or `terminal_watch` | Needs state, timeout, pattern matching |
| Interactive program (vim, top, psql) | `terminal_send` + `terminal_read` | Raw keystroke control |
| Background task | `exec` with `timeout` | No interaction needed |

### 6.4 MCP Notifications for Proactive AI

MCP supports server-initiated notifications via SSE. The Mjolnir MCP server can push terminal events to the AI:

- `terminal.signal_received` -- Human used the `claude` function
- `terminal.command_completed` -- A long-running command finished
- `terminal.error_detected` -- An error pattern appeared in terminal output
- `terminal.session_ended` -- The tmux session was closed

These notifications enable the AI to be proactive -- it does not have to poll for signals.

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/terminal.signal_received",
  "params": {
    "vm_id": "abc-123",
    "signal": {
      "message": "this build is failing, can you help?",
      "context": "...",
      "last_exit_code": 2
    }
  }
}
```

For this to work within Claude Code's current architecture, the MCP server would need to support SSE notifications, and Claude Code would need to handle them (which is supported in the MCP spec but may not be fully implemented in all clients).

---

## 7. Security Considerations

### 7.1 Credential Exposure

A shared terminal session means the AI sees everything the human types, including:

- Passwords typed at `sudo` prompts
- API keys pasted into environment variables
- SSH keys displayed via `cat`
- Database connection strings
- Tokens in `.env` files

**Mitigations:**

1. **Input filtering:** The guest agent can detect and redact common secret patterns in captured output before sending to the AI. Patterns: `password:`, `token=`, `API_KEY=`, base64-encoded JWTs, AWS access keys (`AKIA...`), etc.

2. **Selective capture:** Only capture output, not input. When the human types a password, the terminal does not echo it (stdin echo is off for password prompts). If the agent only captures the output side of the PTY, passwords typed at prompts are not captured.

3. **Credential-aware context stripping:** Before sending terminal context to the AI, run a secret scanner (like `truffleHog` patterns or `detect-secrets`) on the captured text.

4. **Explicit session modes:** The human can put the session in "private mode" (a keybinding or command) that pauses AI observation. Similar to incognito mode in browsers.

```bash
# Pause AI observation:
claude --private    # guest agent stops capturing
# Do sensitive work...
claude --resume     # guest agent resumes
```

### 7.2 Command Injection

If the AI sends commands via `terminal_send`, and those commands contain user-controlled input (e.g., from a file path the human mentioned), there is a command injection risk. The AI might construct:

```bash
cat /path/with; rm -rf /  # if the path was malicious
```

**Mitigations:**

1. **Shell escaping:** The MCP tool implementation should escape all command arguments using proper shell quoting. When using `terminal_send` with a `command`, the guest agent should use `printf '%q'` or equivalent to escape arguments.

2. **Allowlist enforcement:** For critical operations, maintain an allowlist of permitted command prefixes. The guest agent can reject commands that start with dangerous patterns (`rm -rf /`, `dd if=`, `mkfs`, `:(){:|:&};:`).

3. **Confirmation for destructive commands:** The guest agent can intercept commands matching destructive patterns and display a confirmation prompt in the terminal before executing. This puts the human in the loop for dangerous operations.

4. **Sandboxing:** The VM itself is the sandbox. This is Mjolnir's strongest security property. Even if the AI executes `rm -rf /`, the damage is contained to a single microVM that can be destroyed and recreated from a snapshot. This is fundamentally better than running AI commands on the host.

### 7.3 Session Hijacking

If the signaling channel (between human's shell function and guest agent) is not authenticated, a malicious process in the VM could forge signals to the AI.

**Mitigations:**

1. **Socket permissions:** The signaling socket (`/run/claude/agent.sock`) should be owned by the user and mode 0600. Only the user's processes can write to it.

2. **Token-based signal authentication:** The `claude` shell function includes a per-session token (generated at session setup) in each signal. The guest agent validates the token.

3. **Signal rate limiting:** Limit the rate of signals to prevent abuse (e.g., a fork bomb that floods the AI with signals).

### 7.4 Privilege Escalation

The AI agent (via MCP) has access to terminal tools. The human may be running as root in the VM. The AI's commands execute with the same privileges as the shell session.

**Mitigations:**

1. **Principle of least privilege:** The shared terminal session should run as a non-root user by default. The AI should not have sudo without explicit human approval.

2. **Command audit log:** All commands sent via `terminal_send` are logged by the guest agent with timestamps, the command text, and whether it was AI-initiated or human-initiated. This audit log is available via MCP resource (`mjolnir://vms/{id}/terminal-audit`).

3. **Capability-based access:** The MCP tool authorization can restrict which VMs the AI can access and what operations it can perform (read-only vs read-write terminal access).

### 7.5 Information Leakage

Terminal output captured by the AI is sent to the LLM provider (Anthropic). The human should be aware that everything in the shared session is potentially visible to the AI provider.

**Mitigations:**

1. **Clear disclosure:** When a shared session is established, display a banner: "This terminal session is shared with an AI assistant. Terminal content may be sent to the AI provider."

2. **Private mode:** As described above, allow the human to pause AI observation.

3. **Data retention policies:** Understand and communicate the AI provider's data retention policies for tool outputs.

---

## 8. Recommended Architecture for Mjolnir

### 8.1 High-Level Design

```
+------------------------------------------------------------------+
|  Human's Machine (macOS)                                          |
|                                                                   |
|  +-----------+    +------------------------------------------+    |
|  | iTerm2    |    | Claude Code                              |    |
|  |           |    |                                          |    |
|  | Full-     |    |  MCP Client                              |    |
|  | screen    |    |    |                                     |    |
|  | terminal  |    |    | MCP tool calls                      |    |
|  |           |    |    | (terminal_read, terminal_send, etc.) |    |
|  +-----+-----+    +----+-------------------------------------+    |
|        |               |                                          |
|        | Iroh/SSH       | MCP (HTTP)                              |
|        |               |                                          |
+--------+---------------+------------------------------------------+
         |               |
+--------v---------------v------------------------------------------+
|  Mjolnir Host                                                     |
|                                                                   |
|  +-------------------+    +-----------------------------+         |
|  | MCP Server        |    | Iroh Relay / SSH Server     |         |
|  | (Elixir)          |    |                             |         |
|  |                   |    |                             |         |
|  | terminal_* tools  |--->| vsock to VM                 |         |
|  | exec tool         |    |                             |         |
|  +-------------------+    +-------------+---------------+         |
|                                         |                         |
|                            vsock        |                         |
|                                         |                         |
+------------------------------------------------------------------+
         |                                |
+--------v--------------------------------v-------------------------+
|  MicroVM                                                          |
|                                                                   |
|  +-------------------+    +----------------------------+          |
|  | Guest Agent       |    | tmux session: "shared"     |          |
|  | (Rust)            |    |                            |          |
|  |                   |    |  +----------------------+  |          |
|  | - Signal watcher  |<---+  | Shell (bash/zsh)     |  |         |
|  | - PTY capture     |    |  | Human is typing here |  |         |
|  | - ANSI stripping  |    |  +----------------------+  |          |
|  | - tmux control    |    |                            |          |
|  |                   |    | Human attached via Iroh    |          |
|  +-------------------+    | AI accesses via guest agent|          |
|                            +----------------------------+          |
|  Signal channel:                                                   |
|  /run/claude/agent.sock  <-- claude() shell function writes here  |
|                                                                   |
+-------------------------------------------------------------------+
```

### 8.2 Component Responsibilities

**Guest Agent (Rust, in VM)**

The guest agent is the key new component. It runs inside the VM and mediates between the AI (via the MCP server) and the terminal session (tmux):

- Manages tmux sessions (create, attach, capture, send keys)
- Strips ANSI escape sequences from captured output
- Watches the signal socket for human-to-AI messages
- Provides a vsock-based API that the Mjolnir host calls for terminal operations
- Logs all AI-initiated commands for audit
- Implements credential detection and redaction

The guest agent already exists (it handles the vsock protocol for `exec`). Terminal support is an extension of its capabilities.

**MCP Server (Elixir, on host)**

The MCP server translates terminal tool calls into vsock messages to the guest agent:

```
terminal_read(vm_id)
  -> vsock to VM's guest agent
  -> guest agent runs `tmux capture-pane`
  -> strips ANSI
  -> returns clean text via vsock
  -> MCP server returns to Claude Code
```

**Signal flow (human to AI):**

```
Human types: claude "help me with this"
  -> shell function writes to /run/claude/agent.sock
  -> guest agent reads signal
  -> guest agent sends via vsock to host
  -> host MCP server emits SSE notification to Claude Code
  -> Claude Code receives notification, calls terminal_read for context
  -> Claude Code analyzes and responds (via terminal_send or terminal_notify)
```

**Signal flow (AI to human):**

```
Claude Code calls terminal_notify(vm_id, "I found the bug, fixing now...")
  -> MCP server sends via vsock to guest agent
  -> guest agent runs tmux display-message "AI: I found the bug, fixing now..."
  -> human sees message in tmux status bar
```

### 8.3 The tmux Session Model

tmux is the correct abstraction for shared terminal state. Here is why:

1. **Single source of truth:** tmux owns the PTY and terminal buffer. Both the human (attached via Iroh/SSH) and the AI (via guest agent's tmux commands) interact with the same session.

2. **Concurrent access:** tmux natively supports multiple attached clients. The human and the guest agent can both be "attached" simultaneously.

3. **Rich control API:** `tmux send-keys`, `tmux capture-pane`, `tmux display-message`, `tmux split-window` -- all the primitives we need are built-in.

4. **Window/pane management:** The AI can create additional panes for its own work without disrupting the human's view:

```
+---------------------------+
|                           |
|  Human's main shell       |
|  (pane 0)                 |
|                           |
+---------------------------+
| AI scratch pane (pane 1)  |
| (AI runs commands here,   |
|  human can observe)       |
+---------------------------+
```

5. **Session persistence:** If the human disconnects (closes iTerm2), the tmux session continues. The AI can keep working. The human can reattach later.

### 8.4 Connection Flow

Step-by-step for the happy path:

1. **Human asks Claude Code to start a VM session:**
   "Set up a dev environment and open a terminal for me"

2. **Claude Code spawns a VM:**
   `spawn_vm` -> gets `vm_id`

3. **Claude Code opens a shared terminal:**
   `terminal_open(vm_id, session_name="dev")` -> gets `session_id` and `connection_command`

4. **Claude Code tells the human how to connect:**
   "Run this in iTerm2: `mjolnir connect <vm_id> --session dev`"

5. **Human connects:**
   Opens iTerm2, runs the connect command, gets a full-screen shell inside the VM's tmux session.

6. **Human works in the terminal.**
   Claude Code is idle but can observe if asked.

7. **Human wants AI help:**
   Types `claude "the tests are failing, can you look at the output?"`

8. **Claude Code receives the signal:**
   Calls `terminal_read` to see the terminal content, analyzes the test output, and either:
   - Responds via `terminal_notify` ("The test failure is in auth.test.ts line 42, the mock is returning undefined")
   - Or takes action via `terminal_send` (runs the fix command)

9. **AI hands back:**
   Calls `terminal_notify` ("Done -- I fixed the mock and re-ran the tests. All passing now.")

10. **Human continues working.**

### 8.5 Alternative: WebRTC Data Channel for Terminal Streaming

The dual-layer architecture document describes a `pty:{session_id}` data channel for real-time terminal streaming over WebRTC. This is an alternative to the vsock-based approach described above.

With WebRTC, the terminal data would flow:

```
Guest agent -> WebRTC data channel "pty:dev" -> Claude Code (as WebRTC peer)
```

This would enable real-time streaming of terminal output to the AI, rather than snapshot-based capture. However:

- Claude Code does not currently support WebRTC peer connections
- The MCP tool model (request-response) is not well-suited to continuous streams
- The vsock + snapshot approach is simpler and sufficient for most use cases

**Recommendation:** Start with the vsock + tmux snapshot model. Add WebRTC terminal streaming later if real-time observation proves necessary (e.g., for monitoring long-running deploys or watching log output).

---

## 9. Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)

**Goal:** AI can interact with a persistent terminal session in a VM.

Work items:
- Extend the guest agent to manage tmux sessions (create, list, capture, send-keys)
- Add vsock message types for terminal operations
- Implement ANSI stripping in the guest agent (use a Rust crate like `strip-ansi-escapes`)
- Add MCP tools: `terminal_open`, `terminal_read`, `terminal_send`, `terminal_send_and_read`, `terminal_list`, `terminal_close`
- Update `mjolnir connect` to attach to named tmux sessions

**Exit criteria:** Claude Code can open a terminal in a VM, run commands, read output, and the human can attach to the same session via `mjolnir connect`.

### Phase 2: Signaling (Weeks 3-4)

**Goal:** Human and AI can communicate within the shared session.

Work items:
- Implement the `claude` shell function (installed in VM's shell profile by guest agent)
- Implement the signal socket watcher in the guest agent
- Add MCP tools: `terminal_signal_read`, `terminal_notify`
- Add MCP notification: `terminal.signal_received`
- Implement tmux status bar integration (show AI state: idle/thinking/working)
- Add the `terminal_watch` tool for pattern-based waiting

**Exit criteria:** Human can type `claude "help"` and the AI receives the signal with context. AI can send notifications visible in the terminal.

### Phase 3: Polish and Safety (Weeks 5-6)

**Goal:** Production-quality UX and security.

Work items:
- Credential detection and redaction in captured output
- Private mode (`claude --private` / `claude --resume`)
- Command audit logging
- Intelligent context truncation (prompt-boundary-aware)
- Error pattern detection for proactive AI notification
- Documentation and setup guides

**Exit criteria:** A human can work in a VM terminal, seamlessly invoke AI assistance, and trust that credentials are handled safely.

### Phase 4: Advanced Features (Future)

- WebRTC-based real-time terminal streaming
- Multi-pane management (AI opens its own pane for background work)
- Session recording and replay
- Multi-VM terminal orchestration (AI manages terminals in N VMs simultaneously)
- iTerm2 integration (custom triggers, tmux control mode)
- Voice-to-terminal (human says "Claude, take a look at this" via mic)

---

## 10. Open Questions and Trade-offs

### 10.1 tmux Dependency

**Question:** Should we require tmux in every VM?

**Trade-off:** tmux provides the best shared session primitive (concurrent access, capture, send-keys, persistence). Without it, we need to build these capabilities into the guest agent (PTY multiplexing, buffer management, etc.). The cost of requiring tmux is small (it is ubiquitous and lightweight). The cost of reimplementing its functionality is large.

**Recommendation:** Require tmux. Include it in all base VM images. The guest agent creates tmux sessions automatically.

### 10.2 Push vs Pull for AI Context

**Question:** Should the AI actively monitor the terminal (push/streaming) or only look when asked (pull/snapshot)?

**Trade-off:** Push enables proactive assistance ("I noticed your build failed, want me to help?") but uses API credits continuously and may feel intrusive. Pull is cheaper and respects human autonomy but means the AI is blind between interactions.

**Recommendation:** Default to pull (snapshot on demand). Add opt-in push for specific use cases (watching for build completion, monitoring deploys). The human controls the level of AI observation.

### 10.3 Granularity of AI Terminal Access

**Question:** Should the AI send raw keystrokes or higher-level operations?

**Trade-off:** Raw keystrokes (`terminal_send` with `keys: "C-c"`) give the AI maximum flexibility but are fragile (depend on terminal state, cursor position, etc.). Higher-level operations (`terminal_send_and_read` with `command: "make test"`) are more reliable but cannot handle interactive programs.

**Recommendation:** Provide both. `terminal_send_and_read` for most cases (reliable, wait-for-prompt semantics). `terminal_send` with raw keys for interactive programs (vim, psql). The AI should prefer the higher-level tool unless it specifically needs keystroke control.

### 10.4 Who Drives?

**Question:** Should there be explicit "driver" state (human is driving / AI is driving) or implicit sharing?

**Trade-off:** Explicit driver state prevents conflicts (only one participant types at a time) but adds ceremony (must explicitly hand off). Implicit sharing is more fluid but risks the AI typing while the human is mid-command.

**Recommendation:** No explicit lock, but the AI should be conservative. The AI should:
1. Always read the terminal state before sending commands (check if the human is mid-command)
2. Notify the human before taking action ("I'm going to run `make test`, OK?")
3. Prefer notification over action (tell the human what to do, rather than doing it, unless explicitly asked to take over)
4. If the human signals "take over," the AI can act freely until it signals "done"

### 10.5 Multiple Terminal Sessions

**Question:** Should the AI manage multiple simultaneous terminal sessions?

**Trade-off:** Multiple sessions allow the AI to run background tasks without disrupting the human's session. But managing multiple sessions adds complexity and makes it harder for the human to understand what the AI is doing.

**Recommendation:** Support multiple sessions (tmux makes this free). Default pattern: one "shared" session where both human and AI interact, plus AI can create "background" sessions for its own work. The human can view background sessions if they want (`tmux switch-client`).

### 10.6 Context Window Budget

**Question:** How much terminal context should the AI capture?

The captured terminal text consumes the AI's context window. Too much wastes tokens; too little leaves the AI without necessary context.

**Recommendation:** Default to capturing the last 100 lines of visible content plus scrollback. Provide a `scrollback_lines` parameter for the AI to request more if needed. The guest agent should perform intelligent truncation:
- Last 3 command-output pairs in full
- Older content summarized as line counts
- Error lines always included regardless of position
- Total capped at approximately 4000 tokens (roughly 16KB of text)

---

## Appendix A: Prior Art References

### Terminal Sharing Tools
- **tmux**: Session multiplexing, socket sharing, `capture-pane`, `send-keys` -- the core primitives
- **tmate**: tmux fork with SSH relay for remote sharing -- proves network relay model works
- **VS Code Live Share**: Explicit terminal sharing with role-based access -- good UX patterns
- **Tuple**: Screen sharing with driver/navigator roles -- control handoff model
- **Teleconsole (defunct)**: Simple shared PTY via Teleport -- minimal viable approach

### AI Agent Terminal Tools
- **Claude Code Bash tool**: Stateless exec, no persistence, no sharing
- **Cursor terminal integration**: Persistent terminal via VS Code API, AI types into user's terminal
- **Devin**: Full VM workspace, browser-based observation, human can take over
- **SWE-agent**: Mediated shell with custom commands, restricted action space
- **Aider**: Human-in-the-loop, AI proposes commands, human approves

### Context Capture
- **tmux capture-pane**: Point-in-time buffer snapshot, optional ANSI, configurable scrollback
- **script/typescript**: Continuous I/O recording to file, includes timing data
- **PTY interposition**: Agent sits between transport and shell, captures all I/O
- **Terminal emulator libraries**: `vt100` (Rust), `node-pty` + `xterm.js` (JS), `pyte` (Python) -- parse ANSI into virtual screen buffer

### Signaling Mechanisms
- **Shell functions**: `claude()` writes to socket/file, captures last command context
- **File watchers**: inotify/FSEvents on a signal file, works from any process
- **Named pipes (FIFO)**: Blocking signal delivery, one message at a time
- **Unix domain sockets**: Bidirectional, non-blocking, structured protocol possible
- **iTerm2 escape sequences**: `\033]1337;SetUserVar=...` for terminal-native signaling
- **tmux hooks**: `after-send-keys`, `pane-set-clipboard` -- tmux event system

## Appendix B: Related Mjolnir Architecture

This design builds on:
- **Existing MCP tools**: `exec`, `await_pty`, `spawn_vm`, `get_connection_ticket` (see MCP tool definitions in Mjolnir's MCP server)
- **Dual-layer architecture**: MCP control plane + WebRTC data plane (see `docs/plans/initiatives/dual-layer-architecture.md`)
- **Guest agent**: Rust-based agent in each VM that handles vsock communication (see Mjolnir main repo)
- **Iroh connectivity**: P2P QUIC connections for shell access (`mjolnir connect`)
- **WebRTC mesh**: Signaling server for peer-to-peer data channels (`mjolnir-mesh`)

The terminal sharing feature sits at the intersection of the MCP control plane (tool calls for terminal operations) and the existing PTY infrastructure (vsock + guest agent + Iroh). It does not require WebRTC in Phase 1-3 but can leverage WebRTC data channels for real-time streaming in Phase 4.
