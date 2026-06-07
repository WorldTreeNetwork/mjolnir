# Mjolnir Forgejo Runner — Architecture & Epics

## Overview

Execute Forgejo Actions CI/CD jobs inside Mjolnir microVMs. Fork the official `forgejo-runner` Go binary, replace its Docker executor with a Mjolnir executor that spawns VMs via the HTTP API. The Go binary handles all workflow intelligence (nektos/act: YAML parsing, expression eval, step FSM, matrix, composite actions). Elixir/OTP supervises the runner binary as an Erlang Port and provides the VM sandbox + log infrastructure.

## Architecture Decision: Forked Runner + Mjolnir Executor

```
Forgejo Server (Connect-RPC over HTTP)
    ↕
forgejo-runner (forked Go binary, Erlang Port)
  ├── Connect-RPC client (registration, polling, log upload)
  ├── nektos/act engine (workflow parsing, expression eval, step FSM)
  └── MjolnirExecutor (NEW — replaces DockerExecutor)
        ↕ HTTP to localhost:4000
Mjolnir API
  ├── POST /api/vms              → spawn VM
  ├── POST /api/vms/:id/exec     → run step command
  └── DELETE /api/vms/:id        → teardown
```

**Why fork, not rewrite:** The act expression language (`${{ }}` with functions, contexts, type coercion), matrix strategies, composite actions, `uses:` resolution, and artifact handling represent months of reimplementation. The Go fork delta is ~300 lines (one executor implementation).

## Protocol Reference

Connect-RPC (not gRPC) — plain HTTP POST with protobuf bodies. 5 RPCs total:

```
RunnerService:
  Register(RegisterRequest)   -> RegisterResponse
  Declare(DeclareRequest)     -> DeclareResponse
  FetchTask(FetchTaskRequest) -> FetchTaskResponse
  UpdateTask(UpdateTaskRequest) -> UpdateTaskResponse
  UpdateLog(UpdateLogRequest) -> UpdateLogResponse
```

## Supervision Tree

```
Mjolnir.Supervisor
└── Mjolnir.Runner.Supervisor (rest_for_one)
    ├── Mjolnir.Runner.Server       # Manages Go binary as Erlang Port
    │                                # (same pattern as Postgres.Server)
    └── Mjolnir.Runner.SyslogRouter  # Receives VM syslog, routes to consumers
```

The Go binary owns its own concurrency (job polling, step execution, log upload). Elixir's role is:
1. **Lifecycle** — start/stop/restart the runner binary (Port)
2. **VM sandbox** — provide the HTTP API the executor calls
3. **Log routing** — receive syslog from VMs, forward to structured consumers

### Runner.Server (Erlang Port)

Same pattern as `Mjolnir.Postgres.Server`:

```elixir
Port.open({:spawn_executable, runner_binary_path}, [
  :binary, :exit_status, :use_stdio,
  args: ["daemon", "--config", config_path]
])
```

- Captures stdout/stderr for runner-level diagnostics
- Detects exit, restarts with backoff
- `terminate/2` sends SIGTERM, waits, SIGKILL
- Privilege dropping via `setpriv` if needed (runner doesn't need root)

### MjolnirExecutor (Go, in forked runner)

Implements the `act` container executor interface. Per-job lifecycle:

```go
func (e *MjolnirExecutor) Run(ctx context.Context, step *model.Step) error {
    // 1. Spawn VM (once per job, reuse across steps)
    vm := e.ensureVM(ctx, step.Job)

    // 2. Execute step command
    result := mjolnirExec(vm.ID, step.Run, step.Env)

    // 3. Stream stdout/stderr back through act's log hook
    // (act handles UpdateLog RPC to Forgejo)

    return result.Error
}
```

The executor talks to Mjolnir's HTTP API on localhost. VM lifecycle:
- **Job start** → `POST /api/vms` (spawn with CI base image + repo mount)
- **Each step** → `POST /api/vms/:id/exec` (run command, collect output)
- **Job end** → `DELETE /api/vms/:id` (destroy VM)

## Syslog as Universal VM Log Transport

Instead of piping stdout/stderr through vsock per-command, standardize on **syslog** as the log transport for all VM workloads.

### Design

```
┌─────────── VM ───────────┐     ┌──────── Host (Elixir) ────────┐
│                           │     │                                │
│  CI step (sh -c "...")    │     │  Mjolnir.Runner.SyslogRouter   │
│    └→ stdout/stderr       │     │    ├→ Forgejo (via runner)     │
│         └→ logger(1)      │     │    ├→ journald                 │
│              └→ syslog    │     │    ├→ EventBus                 │
│                   └→ vsock│────→│    └→ file / structured log    │
│                           │     │                                │
│  guest-agent              │     │                                │
│    └→ syslog              │────→│  (same path)                   │
│                           │     │                                │
│  any other process        │     │                                │
│    └→ syslog              │────→│  (same path)                   │
└───────────────────────────┘     └────────────────────────────────┘
```

### Implementation

**Guest side:**
- Minimal syslog daemon in the CI base image (busybox `syslogd` or `socklog`)
- Configured to forward to a vsock address (host CID 2, dedicated port e.g. 5001)
- CI steps: wrap with `logger -t ci-step` or redirect fd to syslog
- Guest agent already has structured logging — route through syslog too

**Host side:**
- `Mjolnir.Syslog.Listener` — GenServer accepting syslog messages over vsock per VM
- Parses RFC 5424 syslog frames (structured data, priority, facility, tag)
- Routes based on tag/facility:
  - `ci-step.*` → `Runner.SyslogRouter` → act's log reporter → Forgejo
  - `guest-agent.*` → `Mjolnir.EventBus` for observability
  - `*` → journald passthrough or file sink

**Why syslog:**
- Already the Linux standard — every process can use it (logger, libc syslog(), /dev/log)
- Structured (priority, facility, tag, timestamp) without inventing a wire format
- Single transport path for all VM log sources (CI, agent, system)
- Easy to tap at the Elixir level for routing, filtering, aggregation
- Decouples log production (guest) from log consumption (host decides where it goes)

### For CI Specifically

The Go runner's act engine already handles `UpdateLog` RPC to Forgejo. The syslog path gives us a second channel:
- **Primary (CI logs to Forgejo):** Act captures step stdout/stderr directly via the executor, sends via `UpdateLog`. No change needed.
- **Secondary (observability):** Same output also flows through syslog → host for local logging, metrics, debugging. This is the "pipe it wherever" layer.

For long-running or background VM workloads (not CI), syslog becomes the **primary** log path.

## Repo Workspace Strategy

### Primary: Second Virtio-FS Mount (Read-Only Bare Repo)

```
VM filesystem layout:
/                    ← rootfs via virtio-fs tag "myfs" (rw)
/workspace/repo.git  ← bare repo via virtio-fs tag "repo" (ro)
/workspace/src/      ← git checkout destination (rw, on rootfs)
```

The MjolnirExecutor tells Mjolnir to mount Forgejo's bare repo directory
(`/var/lib/forgejo/data/repositories/<owner>/<repo>.git`) as a second
virtio-fs. Guest does `git clone /workspace/repo.git /workspace/src --branch <ref>`.

Zero-copy repo access. Read-only mount prevents job from tampering with git data.
Forgejo repos are on ext4 — virtiofsd handles this fine, no BTRFS needed.

### Changes needed:
- `Mjolnir.VirtioFS` — support multiple tagged instances per VM
- `Mjolnir.CloudHypervisor.Config` — accept N fs entries (already an array)
- `Mjolnir.VM` — manage N virtiofsd ports, cleanup all on teardown

### Fallback: Git Clone Over Network
Standard `actions/checkout` clones via HTTP/SSH. Works with zero changes, slower.

## Configuration

```elixir
# config/prod.exs
config :mjolnir, Mjolnir.Runner,
  enabled: false,  # feature flag, like pg_enabled
  runner_binary: "/usr/local/bin/forgejo-runner-mjolnir",
  runner_config: "/etc/mjolnir/runner.yml",
  runner_state_dir: "/var/lib/mjolnir/runner",
  forgejo_url: "http://127.0.0.1:3000",
  labels: ["ubuntu-24.04:vm://ubuntu-24.04"],
  max_concurrent_jobs: 4,
  repo_root: "/var/lib/forgejo/data/repositories",
  job_timeout_ms: 3_600_000,
  syslog_vsock_port: 5001

config :mjolnir, Mjolnir.Syslog,
  enabled: true,  # independent of runner — useful for all VMs
  vsock_port: 5001,
  default_sink: :journald  # :journald | :file | :eventbus
```

## Security Model

- Each CI job runs in its own microVM (kernel isolation, not namespaces)
- VM destroyed after job (no state leakage)
- Repo mounted read-only via virtio-fs
- Secrets injected as env vars by the Go runner (act handles this)
- Network: NAT'd internet access (same as regular VMs)
- Runner binary runs as unprivileged user (not root)

---

## Epics & Effort Estimates

Effort scale: S (1-2 days), M (3-5 days), L (1-2 weeks)

### Epic 1: Fork Runner + MjolnirExecutor — **M**

Fork `forgejo/runner`, implement MjolnirExecutor that calls Mjolnir HTTP API instead of Docker API.

**Tasks:**
- [ ] Fork `code.forgejo.org/forgejo/runner`, set up Go build
- [ ] Implement `MjolnirExecutor` conforming to act's container interface
  - `ensureVM()` → `POST /api/vms` (spawn with base image + extra mounts)
  - `execStep()` → `POST /api/vms/:id/exec` (run command, collect output)
  - `teardown()` → `DELETE /api/vms/:id`
- [ ] Wire executor into runner's config (new label scheme: `ubuntu-24.04:mjolnir://...`)
- [ ] Pass repo mount info via executor context (owner/repo from task context)
- [ ] Cross-compile for server target
- [ ] Unit tests with mocked Mjolnir API

**Dependencies:** None
**Risk:** Medium — need to understand act's executor interface. Well-documented in nektos/act.

---

### Epic 2: Runner Erlang Port Supervisor — **S**

Manage the Go binary as an Erlang Port under OTP supervision.

**Tasks:**
- [ ] `Runner.Server` GenServer (mirrors `Postgres.Server` pattern)
  - `Port.open/2` with `:binary, :exit_status, :use_stdio`
  - Startup wait (probe readiness via runner's health endpoint or log output)
  - Graceful shutdown: SIGTERM → wait → SIGKILL
  - Restart with exponential backoff on crash
- [ ] Feature flag: `runner_enabled` (default false)
- [ ] `Runner.Supervisor` added to main supervision tree (conditional)
- [ ] Config generation: write runner YAML config from Elixir config on boot
- [ ] Registration state persistence (`runner_state_dir`)

**Dependencies:** Epic 1 (need the binary to supervise)
**Risk:** Low — pattern is proven with Postgres

---

### Epic 3: Multi-VirtioFS Support — **M**

Mount multiple host directories into a single VM via separate virtiofsd instances.

**Tasks:**
- [ ] `VirtioFS.start/3` → accept a `tag` parameter (default `"myfs"`)
- [ ] `VirtioFS.start_many/1` → start N instances, return list of ports + socket paths
- [ ] `CloudHypervisor.Config` — accept list of `{tag, socket}` fs entries
- [ ] `VM` state — track `virtiofsd_ports: [port()]`, cleanup all on teardown
- [ ] API extension: `POST /api/vms` accepts optional `extra_mounts` list
  - `[%{tag: "repo", path: "/var/lib/forgejo/.../repo.git", readonly: true}]`
- [ ] Guest-side: mount helper script or `VM.exec` post-boot mount
- [ ] Integration test: VM with two virtio-fs mounts, verify read-only enforcement

**Dependencies:** None (parallel with Epics 1-2)
**Risk:** Medium — untested in our stack but CH supports it

---

### Epic 4: Syslog Infrastructure — **M**

Universal syslog-over-vsock transport for all VM log output.

**Tasks:**
- [ ] `Mjolnir.Syslog.Listener` GenServer — accept vsock connections on port 5001
  - One connection per VM, identified by CID
  - Parse RFC 5424 syslog messages (or RFC 3164 for busybox compat)
  - Emit `{:syslog, vm_id, parsed_message}` to subscribers
- [ ] `Mjolnir.Syslog.Router` — route by tag/facility to sinks
  - `:journald` — forward to host journal with VM metadata
  - `:eventbus` — publish on `Mjolnir.EventBus`
  - `:file` — per-VM log file under state dir
- [ ] Guest base image: install `busybox syslogd` or `socklog`
  - Configure remote forwarding to vsock CID 2, port 5001
- [ ] CI base image: wrapper script that pipes step output through `logger -t ci`
- [ ] Integration test: VM process logs → host syslog listener → parsed output

**Dependencies:** None (parallel with everything, useful beyond CI)
**Risk:** Low-Medium — syslog parsing is well-defined; vsock transport is the novel part

---

### Epic 5: CI Base Image — **S**

Rootfs image optimized for CI workloads.

**Tasks:**
- [ ] Base image: git, curl, build-essential, common runtimes (node, python, go)
- [ ] Syslog daemon configured for vsock forwarding (Epic 4)
- [ ] Auto-mount script for additional virtio-fs tags on boot
- [ ] Workspace directory structure (`/workspace/src`, `/workspace/cache`)
- [ ] Store as `@base/ci-ubuntu-24.04` BTRFS subvolume
- [ ] Justfile recipe: `just build-ci-image`

**Dependencies:** Epic 4 (syslog config in image)
**Risk:** Low

---

### Epic 6: End-to-End Integration — **M**

Full lifecycle: push to Forgejo → runner picks up → VM executes → logs + status in Forgejo UI.

**Tasks:**
- [ ] Deploy forked runner binary to server
- [ ] Register runner with Forgejo instance
- [ ] Test workflow: `.forgejo/workflows/test.yml` with simple shell steps
- [ ] Verify: VM spawned, repo mounted ro, steps executed, logs visible in Forgejo
- [ ] Verify: VM destroyed after job, no resource leaks (TAPs, sockets, subvolumes)
- [ ] Verify: syslog reaches host, visible in journald
- [ ] Failure modes: step failure, timeout, VM crash → correct status reported
- [ ] Dogfood: CI pipeline for mjolnir itself

**Dependencies:** All previous epics
**Risk:** Medium — integration complexity

---

## Summary

| # | Epic | Effort | Parallel? |
|---|------|--------|-----------|
| 1 | Fork Runner + MjolnirExecutor | M (3-5d) | Yes |
| 2 | Runner Erlang Port Supervisor | S (1-2d) | After 1 |
| 3 | Multi-VirtioFS Support | M (3-5d) | Yes |
| 4 | Syslog Infrastructure | M (3-5d) | Yes |
| 5 | CI Base Image | S (1-2d) | After 4 |
| 6 | E2E Integration | M (3-5d) | After all |

**Critical path:** 1 → 2 → 6 (~2-3 weeks)
**With parallelism (3, 4, 5 alongside):** ~3 weeks total

## Future (Post-V1)

- Artifact upload/download via Forgejo API
- Job caching (BTRFS snapshots of workspace for cache restore)
- Snapshot-based fast start (checkpoint a "warm" CI VM, CoW restore per-job)
- Ephemeral runners (register per-job, deregister after)
- Multi-host runner (dispatch jobs to remote Mjolnir nodes)
- Syslog → OpenTelemetry bridge for distributed tracing
- Network policy per-label (deny internet for certain jobs)
