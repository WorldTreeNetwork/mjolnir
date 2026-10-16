# add-forge-ssh-transport

> **PENDING**

Bead `mjolnir-jl1.1` (parent `mjolnir-jl1`). Depends on `mjolnir-8uo` (closed). Blocks `mjolnir-9u0`.

**Rigor:** change

**Preparation (2026-10-15 /run):** still the stub. `Resource.read_file(:ssh, ...)` and `Host.apply_entry` for `:ssh` return `:ssh_transport_not_implemented_yet`. `POST /api/forge/hosts` already accepts `transport: "ssh"` and starts a Host worker. `mj forge plan --host` already calls `GET /api/forge/plan?host=`. No `openspec/specs/forge`. Steer menu was declined; the two forks below are `[AUTO]`, not a campaign grant.

## Why

Forge can reconcile only the host it is running on. A second machine is a named worker that cannot observe files, so `mj forge plan` cannot show drift there.

## What

- Capability `forge` (new living spec when this folds).
- One OpenSSH ControlMaster connection per host. The host string is the SSH destination. Identity comes from the control plane's ssh config and agent.
- `plan` reads declared file paths through that connection and returns a diff.
- A dropped connection backs off that Host worker. `Forge.Supervisor` stays up.

## Impact

- Capabilities: ADDED `forge`
- ADRs: none

## User journey & surfaces

Operator, from `POST /api/forge/hosts` and `mj forge plan --host <user@host>`.

- Working: the host worker is up, plan prints a diff built from remote file reads, and nothing on that host was written.
- Empty: the host has no declared resources, so the diff is empty.
- Failed: ssh does not connect, or the connection drops. That worker backs off. Other hosts keep planning. The command reports the failure.
- Off: `transport` omitted or `local` stays the current local observe path.

## Out of scope

- Apply, adopt, and delete over SSH. `Host.apply_entry` for `:ssh` keeps returning `:ssh_transport_not_implemented_yet`. A later change, not this one.
- Probe and enumerate kinds. They stay local.
- Storing passwords or private keys in Forge.
- `:erlexec`. Decided 2026-09-10: `ssh(1)` ControlMaster.
- The on-host Rust agent (`mjolnir-9u0`).
- Multi-host scheduling. One host proves the transport.
