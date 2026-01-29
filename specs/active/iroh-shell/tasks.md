# Implementation Tasks: Iroh Shell (Phase 2)

**Task ID:** iroh-shell
**Created:** 2026-01-28
**Status:** Ready for Implementation
**Phase:** 2 (Guest Outbound Networking complete)

## Summary

| Metric | Value |
|--------|-------|
| Total Tasks | 12 |
| Estimated Effort | 3-5 days |
| Phases | 1 (Phase 2 only) |

---

## Task 2.1: Measure Baseline Binary Size

**Description:** Record current guest agent binary size before adding iroh-net

**Acceptance Criteria:**
- [ ] Build current agent in release mode
- [ ] Record size in bytes and human-readable format
- [ ] Document in this file or handoff notes

**Effort:** 30 min
**Priority:** High (do first, blocks nothing but informs later)
**Dependencies:** None

**Commands:**
```bash
cd native/mjolnir_guest_agent
cargo build --release
ls -lh target/release/mjolnir-agent
```

---

## Task 2.2: Add iroh-net to Cargo.toml

**Description:** Add iroh-net, iroh-base, and PTY dependencies to guest agent

**Acceptance Criteria:**
- [ ] `cargo build` succeeds with new deps
- [ ] No dependency conflicts
- [ ] Record new binary size (delta from 2.1)

**Effort:** 1-2 hours (may need to resolve version conflicts)
**Priority:** High
**Dependencies:** 2.1

**Changes:**
- `native/mjolnir_guest_agent/Cargo.toml` — add deps per phase2-detail.md

---

## Task 2.3: Extract Vsock Module

**Description:** Refactor main.rs into modules for cleaner structure

**Acceptance Criteria:**
- [ ] Create `src/vsock.rs` with existing vsock code
- [ ] Create `src/protocol.rs` with message types
- [ ] `cargo build` and `cargo test` pass
- [ ] Existing vsock functionality unchanged

**Effort:** 2 hours
**Priority:** High
**Dependencies:** 2.2

**Files:**
- `src/main.rs` → slim orchestration
- `src/vsock.rs` → vsock listener + handlers
- `src/protocol.rs` → VsockRequest, VsockResponse, IrohReady, ShellMessage

---

## Task 2.4: Implement Keypair Load/Generate

**Description:** Add function to load existing key from `/etc/mjolnir/iroh.key` or generate new one

**Acceptance Criteria:**
- [ ] If key file exists, load it
- [ ] If not, generate new key
- [ ] Log whether key was loaded or generated (INFO level)
- [ ] Try to save generated key (ignore errors if dir doesn't exist)
- [ ] Return (SecretKey, bool) tuple

**Effort:** 1-2 hours
**Priority:** High
**Dependencies:** 2.3

**Location:** `src/iroh.rs::load_or_generate_key()`

---

## Task 2.5: Implement PTY Module

**Description:** Create PTY allocation and management using nix crate

**Acceptance Criteria:**
- [ ] `PtySession::spawn(cmd, cols, rows)` works
- [ ] Can write to PTY stdin
- [ ] Can read from PTY stdout
- [ ] `resize(rows, cols)` sends TIOCSWINSZ + SIGWINCH
- [ ] Child process killed on drop
- [ ] Test with standalone Rust binary (doesn't need VM)

**Effort:** 4-6 hours (PTY is tricky)
**Priority:** High
**Dependencies:** 2.2

**Location:** `src/pty.rs`

**Test approach:**
```rust
#[test]
fn test_pty_echo() {
    let mut pty = PtySession::spawn("/bin/cat", 80, 24).unwrap();
    // Write, read back, verify
}
```

---

## Task 2.6: Implement Iroh Endpoint Setup

**Description:** Create Iroh endpoint, connect to relay, generate ticket

**Acceptance Criteria:**
- [ ] Endpoint binds with ALPN `mjolnir-shell/1`
- [ ] Waits for home_relay before proceeding
- [ ] Generates NodeTicket from node_addr
- [ ] Logs node_id and ticket at INFO level

**Effort:** 2-3 hours
**Priority:** High
**Dependencies:** 2.4

**Location:** `src/iroh.rs::run_iroh_server()` (first half)

---

## Task 2.7: Implement Shell Connection Handler

**Description:** Accept Iroh connections, spawn PTY, bidirectional stream

**Acceptance Criteria:**
- [ ] Accept incoming QUIC connection
- [ ] Accept bidirectional stream
- [ ] Spawn PTY with /bin/zsh
- [ ] Forward client data → PTY stdin
- [ ] Forward PTY stdout → client
- [ ] Handle resize messages
- [ ] Send exit message when shell exits
- [ ] Clean disconnect on client hangup

**Effort:** 4-6 hours
**Priority:** High
**Dependencies:** 2.5, 2.6

**Location:** `src/iroh.rs::handle_shell_connection()`

---

## Task 2.8: Implement iroh_ready Vsock Notification

**Description:** Send iroh_ready message to host after relay connects

**Acceptance Criteria:**
- [ ] IrohReady struct serializes correctly
- [ ] Message sent on first vsock connection after Iroh ready
- [ ] Contains node_id, ticket, generated_key fields
- [ ] Host can parse the message

**Effort:** 2 hours
**Priority:** High
**Dependencies:** 2.6, 2.3

**Changes:**
- `src/vsock.rs` — accept iroh_ready via channel, send on connection
- `src/main.rs` — wire up oneshot channel between tasks

---

## Task 2.9: Update Elixir Protocol Module

**Description:** Add iroh_ready parsing to Vsock.Protocol

**Acceptance Criteria:**
- [ ] `parse_iroh_ready/1` function added
- [ ] Returns `{:ok, %{node_id: ..., ticket: ..., generated_key: ...}}`
- [ ] Handles missing generated_key field (default true)

**Effort:** 30 min
**Priority:** High
**Dependencies:** None (can do in parallel)

**Location:** `lib/mjolnir/vsock/protocol.ex`

---

## Task 2.10: Update VM.ex for Shell State

**Description:** Add iroh fields to VM struct, await iroh_ready in boot

**Acceptance Criteria:**
- [ ] VM struct has :iroh_node_id, :iroh_ticket, :shell_ready
- [ ] `do_boot` calls `await_iroh_ready` after network config
- [ ] Timeout of 30s, logs warning if not ready
- [ ] VM still boots even if shell not ready (graceful degradation)

**Effort:** 2-3 hours
**Priority:** High
**Dependencies:** 2.9

**Location:** `lib/mjolnir/vm.ex`

---

## Task 2.11: Add VM Shell API

**Description:** Add get_ticket, node_id, await_shell public functions

**Acceptance Criteria:**
- [ ] `get_ticket/1` returns ticket or {:error, :not_ready}
- [ ] `node_id/1` returns node_id or {:error, :not_ready}
- [ ] `await_shell/2` polls until ready or timeout
- [ ] All handle :not_found correctly

**Effort:** 1 hour
**Priority:** Medium
**Dependencies:** 2.10

**Location:** `lib/mjolnir/vm.ex`

---

## Task 2.12: Integration Tests & Documentation

**Description:** Write tests, measure final binary size, update docs

**Acceptance Criteria:**
- [ ] Test: VM reports shell_ready after boot
- [ ] Test: get_ticket returns valid ticket
- [ ] Test: await_shell returns quickly if already ready
- [ ] Final binary size documented
- [ ] Troubleshooting guide updated for Iroh issues

**Effort:** 3-4 hours
**Priority:** Medium
**Dependencies:** 2.11

**Files:**
- `test/mjolnir/vm_iroh_test.exs`
- `docs/networking-troubleshooting.md` (add Iroh section)

---

## Quick Reference Checklist

- [ ] 2.1: Measure baseline binary size
- [ ] 2.2: Add iroh-net to Cargo.toml
- [ ] 2.3: Extract vsock module
- [ ] 2.4: Implement keypair load/generate
- [ ] 2.5: Implement PTY module
- [ ] 2.6: Implement Iroh endpoint setup
- [ ] 2.7: Implement shell connection handler
- [ ] 2.8: Implement iroh_ready vsock notification
- [ ] 2.9: Update Elixir protocol module
- [ ] 2.10: Update VM.ex for shell state
- [ ] 2.11: Add VM shell API
- [ ] 2.12: Integration tests & documentation

---

## Parallelization Opportunities

These can be done concurrently:
- 2.5 (PTY) and 2.6 (Iroh endpoint) — independent Rust modules
- 2.9 (Elixir protocol) — doesn't depend on Rust changes

Suggested order for single implementer:
```
2.1 → 2.2 → 2.3 → [2.4, 2.5 in parallel] → 2.6 → 2.7 → 2.8 → 2.9 → 2.10 → 2.11 → 2.12
```

---

## Next Steps

1. Start with Task 2.1 (baseline measurement)
2. Run `/implement iroh-shell` to begin execution

---

*Tasks created with SDD 4.0*
