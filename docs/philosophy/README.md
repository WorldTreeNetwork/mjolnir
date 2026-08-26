# Philosophy

Speculative architecture and durable arguments. Not living specs, not
ADRs, not runbooks.

A file here is a position we do not want to re-derive when a session
closes. When a position here is activated, it becomes an ADR under
`docs/decisions/` plus an OpenSpec change. Until then it must not be
read as a SHALL.

In this folder:

- [`deterministic-agency.md`](deterministic-agency.md) — a neural
  network approximates; Mjolnir is the deterministic portion of the
  agent's agency (body, snapshot, mailbox, capability)
- [`mailbox-as-spool.md`](mailbox-as-spool.md) — per-actor filesystem
  spool; 0MQ / π-calculus compose above it

Related notes that predate this folder and still live at `docs/` root:

- [`../everything-is-a-channel.md`](../everything-is-a-channel.md) — named
  channels as the universal primitive; session types vs payload types
- [`../event-queue.md`](../event-queue.md) — email as the stress-tested
  event queue; a stream is a UART
- [`../computational-fabric.md`](../computational-fabric.md) — π/ρ-calculus
  foundations
