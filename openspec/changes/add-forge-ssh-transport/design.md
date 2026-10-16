# Design

## Decisions

1. **ControlMaster via `ssh(1)`.** One multiplexed connection per host string. The 2026-09-10 intend already chose this over `:erlexec`. Do not reopen it.
2. **Plan observes. Apply does not.** `[AUTO]` 2026-10-15 after the steer menu was declined. `plan` reads files and diffs. `apply` over SSH stays the stub. `auto_apply` stays false. A later change can add writes once observe is proven.
3. **No credential store.** The destination is the host string (`user@host`). Keys and the agent stay in the control plane's OpenSSH config. Forge does not grow a password or key field.
4. **Proof is a stubbed executor.** `[AUTO]` 2026-10-15. Tests cover a file observe, a refused non-read command, and backoff. A live `mj forge plan --host duke@laptop` is a journey, not the test gate.

## Shape

`Resource.read_file(:ssh, host, path)` runs one allowed remote read on that host's ControlMaster. Anything else is refused before ssh. `Host.plan` already calls `Resource.observe`; once the read works, the existing diff is the plan. `apply_entry(%{transport: :ssh})` is unchanged. Disconnect is handled in the Host worker: log, backoff, keep the supervisor up.
