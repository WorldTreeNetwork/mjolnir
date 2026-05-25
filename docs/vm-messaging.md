# VM Messaging & Dormancy

This document covers Mjolnir's inter-VM messaging system: how to send messages between VMs, what happens when a VM goes dormant, and the delivery guarantees the system provides.

---

## Sending a Message

```
POST /api/vms/{target_vm_id}/messages
```

```json
{
  "from_vm_id": "sender-uuid-or-external",
  "payload": { "any": "json" }
}
```

- `from_vm_id` — The UUID of the sending VM, or `"external"` for non-VM senders (webhooks, API clients, etc.). When a real VM ID is provided, the API verifies the caller owns both the sender and the target.
- `payload` — Arbitrary JSON. No schema is enforced by the host; interpretation is up to the guest agent and whatever application runs inside the VM.

**Responses:**

| Status | Body | Meaning |
|--------|------|---------|
| 200 | `{"ok": true}` | Message accepted for delivery |
| 404 | `{"error": "not_found"}` | Target VM doesn't exist (not running, not dormant) |
| 500 | `{"error": "message_delivery_failed"}` | Delivery error (vsock failure, restore failure, etc.) |

**Auth scope:** `vms:exec`

**Justfile shortcut:**

```bash
just vm-message <vm-id> '{"from_vm_id": "external", "payload": {"type": "wake"}}'
```

---

## Delivery State Machine

A message takes different paths depending on the target VM's state:

```
                POST /api/vms/{id}/messages
                          │
                          ▼
                 ┌─ VMRegistry lookup ─┐
                 │                     │
              found                 not found
                 │                     │
                 ▼                     ▼
          ┌── VM state? ──┐    DormantRegistry lookup
          │                │           │
       :running        :booting     found?
          │                │       ┌────┴────┐
          ▼                ▼      yes         no
     vsock → guest    queue in     │          │
     (immediate)     GenServer     ▼          ▼
                    (flush after  state?    404
                      boot)     ┌───┴───┐
                            :dormant  :restoring
                                │         │
                                ▼         ▼
                          queue on     retry loop
                          disk +       (5× 200ms)
                          restore      until VM
                          from         appears in
                          snapshot     VMRegistry
```

### Running VM

Message is delivered immediately over the persistent vsock connection to the guest agent. The vsock protocol encodes it as a channel-0 JSON control message:

```json
{
  "type": "deliver_message",
  "id": "correlation-uuid",
  "from_vm_id": "sender-uuid",
  "payload": { ... }
}
```

The guest agent ACKs with `deliver_message_ack`. The ACK is informational — delivery is fire-and-forget from the host's perspective once it hits the vsock wire.

### Booting VM

Message is queued in the VM GenServer's in-memory `message_queue`. All queued messages are flushed to the guest agent over vsock once boot completes and the agent is reachable.

### Dormant VM (wake-on-message)

This is the key behavior: **sending a message to a dormant VM automatically restores it.**

1. Message is persisted in the DormantRegistry's `pending_messages` list (written to disk as JSON).
2. An async Task spawns to restore the VM from its snapshot.
3. The VM boots with its original config and the same UUID.
4. All pending messages are retrieved from the registry and delivered via vsock.
5. The DormantRegistry entry is removed.
6. An `:vm_restored` event is published on the EventBus.

If a second message arrives while restore is already in flight (state = `:restoring`), delivery retries in a loop (5 attempts, 200ms apart) until the VM appears in the VMRegistry.

---

## Going Dormant (handle_done)

A VM goes dormant when the guest agent sends `signal_done` over the vsock control channel. This is initiated by the workload inside the VM — the host doesn't decide when a VM should sleep.

The sequence:

1. Guest agent sends `{"type": "signal_done", "id": "..."}` on vsock channel 0.
2. Host ACKs with `signal_done_ack`.
3. Host calls `VM.handle_done/1` in an async Task:
   - Snapshots the VM's BTRFS subvolume → `dormant-{uuid}-{timestamp}`
   - Saves restore config (base_image, vcpus, memory_mb, iroh settings, owner_id, secrets_mode)
   - Registers in DormantRegistry (persisted to disk)
   - Deletes the StateStore intent record
   - Publishes `:vm_dormant` on EventBus
   - Stops the VM GenServer (`:normal` exit — no automatic restart)

**Restriction:** VMs with `secrets_mode: :persistent` cannot go dormant. There's no way to supply the passphrase during automatic restore, so `handle_done` returns `{:error, :secrets_prevent_dormancy}`. These VMs must be stopped explicitly or snapshotted manually.

---

## EventBus

The EventBus is a separate system from message delivery. It's an in-memory pub/sub for VM lifecycle events, built on Erlang's `:pg` process groups.

**Subscribe:**

```elixir
Mjolnir.EventBus.subscribe(vm_id)    # events for one VM
Mjolnir.EventBus.subscribe(:all)     # all VM events
```

**Event format:**

```elixir
{:mjolnir_event, vm_id, event_type, payload}
```

**Event types:**

| Event | When | Payload |
|-------|------|---------|
| `:vm_spawned` | VM created | `%{vcpus: _, memory_mb: _}` |
| `:vm_stopped` | VM stopped | `%{}` |
| `:vm_dormant` | VM checkpointed and sleeping | `%{snapshot: "dormant-..."}` |
| `:vm_restored` | Dormant VM woken up | `%{snapshot: "dormant-..."}` |
| `:snapshot_created` | Manual snapshot taken | `%{name: "..."}` |
| `:agent_event` | Forwarded from guest agent | varies |

**No persistence, no delivery guarantees.** Events are only delivered to processes currently subscribed. If nothing is listening, events are silently dropped. EventBus is for monitoring and coordination, not for reliable messaging — that's what `deliver_message` is for.

---

## Delivery Guarantees

| Scenario | Guarantee |
|----------|-----------|
| Target is running | At-most-once (vsock send, no host-side retry) |
| Target is booting | Queued in memory, delivered after boot (survives slow boot, lost on host crash) |
| Target is dormant | Queued on disk, delivered after restore (survives host restart) |
| Target doesn't exist | Immediate 404 |
| Host crashes mid-restore | DormantRegistry reloads from disk on next startup; `:restoring` entries reset to `:dormant`, pending messages preserved |

The system prioritizes **availability over exactly-once semantics**. Guest applications that need stronger guarantees should implement their own idempotency (e.g., deduplication by message ID).

---

## Persistence Layout

```
{btrfs_root}/
├── @dormant/
│   └── registry.json          # DormantRegistry state (all dormant VMs + pending messages)
├── @snapshots/
│   └── dormant-{uuid}-{ts}/   # BTRFS subvolume snapshot for each dormant VM
└── @vms/
    └── {uuid}/                # Running VM rootfs (deleted on stop/dormancy)
```

The registry uses atomic writes (temp file → rename → fsync) with a configurable debounce interval (`dormant_flush_delay_ms`, default 250ms). Set `MJOLNIR_DORMANT_FLUSH_DELAY_MS=0` for synchronous flush on every mutation.

---

## Example: Wake-on-Message Round Trip

```bash
# 1. Spawn a VM
just vm-spawn
# → {"id": "abc-123", ...}

# 2. The workload inside finishes and signals done.
#    (Guest agent sends signal_done over vsock.)
#    VM snapshots itself and goes dormant.

# 3. Some time later, send it a message:
just vm-message abc-123 '{"from_vm_id": "external", "payload": {"task": "resume"}}'
# → {"ok": true}

# 4. Behind the scenes:
#    - Message queued in DormantRegistry (disk)
#    - VM restored from snapshot (same UUID)
#    - Guest agent boots, receives the message
#    - VM is now running again

# 5. Verify it's back:
just vm-info abc-123
# → {"id": "abc-123", "state": "running", ...}
```
