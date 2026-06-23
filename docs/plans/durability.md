# Mjolnir Durability & Chaos Resilience

**Status**: Design (2026-04-21)
**Owner**: Duke
**Predecessor**: `test-harness-spec.md`
**Implementation approach**: Option C — this doc first, then scenario-by-scenario (Option B) implementation.

---

## Goals

1. **Mjolnir service restart preserves VMs.** `systemctl restart mjolnir` → same VM UUIDs reappear, same IPs, same in-guest state.
2. **Server reboot preserves VMs.** `systemctl reboot` → on boot, all VMs that were running are running again.
3. **Process-kill resilience.** `pkill -9 beam.smp` or `pkill -9 cloud-hypervisor` → systemd restarts mjolnir, VMs come back.
4. **Connection rot is detectable and self-healing.** Stale vsock, stale Iroh, dead TAP, wiped NAT — all probed and idempotently rebuilt.
5. **Red/green chaos feedback loop.** `mix test --only chaos` drives scenarios against the prod server, produces pass/fail summary.

## Non-goals (for now)

- Multi-host failover / live migration.
- Decoupling Cloud Hypervisor from BEAM lifetime. **By design, CH children die with BEAM** — if the orchestrator is down, nothing can drive the VMs anyway. Resurrection on boot is the contract, not continuous availability.
- Snapshot restore as a lifecycle primitive (tracked separately — it's a feature, not a durability concern).

## Design principles

1. **Filesystem-as-truth for rootfs, state-dir-as-truth for intent.** Rootfs data lives in `@vms/<uuid>/` subvolumes; lifecycle intent lives in `/var/lib/mjolnir/state/<uuid>.json`. Neither is authoritative alone; reconcile diffs the two.
2. **Derive what you can, persist what you can't.** UUID → TAP/MAC/IP/CID is deterministic (already implemented in `lib/mjolnir/network.ex`). Don't persist things that are pure functions of the UUID.
3. **Probe exercises, not just observes.** Every health check sends a byte end-to-end. "Socket open" is not "socket works" (Iroh-rot lesson from 2026-Q1 LLM deploy).
4. **Heal is idempotent destroy-then-create.** Every heal function is safe to call in any state. No "is it broken enough?" decisions at runtime.
5. **Escalate, don't flail.** L0 probe → L1 reconnect → L2 reconfigure → L3 restart agent → L4 restart VM → L5 respawn. Cheap first, nuclear last.

---

## State model

### Derivable (don't persist)

| Property | Source |
|---|---|
| TAP device name | `"mj-" <> first_8(uuid)` in `Mjolnir.Network` |
| MAC address | Hash of UUID |
| IP address | Hash of UUID into 10.0.0.0/8 |
| Vsock CID | First 4 bytes of MD5(UUID), range [3, 0xFFFFFFFF) |
| Socket path | `"#{socket_dir}/#{uuid}.sock"` |

### Persisted: `/var/lib/mjolnir/state/<uuid>.json`

```json
{
  "uuid": "3f2a...",
  "intent": "running",
  "created_at": "2026-04-21T14:00:00Z",
  "last_boot_at": "2026-04-21T14:00:00Z",
  "spawn_config": {
    "vcpus": 2,
    "memory_mb": 1024,
    "base_image": "ubuntu-24.04",
    "boot_args_extra": []
  },
  "identity": {
    "hostname": "vm-3f2a",
    "ssh_authorized_keys_hash": "sha256:...",
    "iroh_node_id": "abc123...",
    "iroh_ticket": "abc123..."
  },
  "dormant": null,
  "runtime": {
    "ch_api_socket": "/var/run/mjolnir/3f2a.sock",
    "vsock_uds": "/var/run/mjolnir/3f2a.vsock"
  }
}
```

**Valid `intent` values**: `running`, `dormant`, `stopped`.
**Dormant shape** (when `intent=dormant`):
```json
"dormant": {
  "snapshot_name": "readonly-agent-v1",
  "snapshotted_at": "2026-04-21T15:00:00Z",
  "wake_on_message": true
}
```

### Atomicity

Writes go to `state/<uuid>.json.tmp` then `rename(2)` over the target. Reads tolerate missing files (treat as "never existed"). Partial writes caught by JSON parse failure → quarantine.

---

## Supervision tree changes

```
Mjolnir.Supervisor (one_for_one)
├── Mjolnir.StateStore         [NEW] — ETS cache over state/*.json, file-backed writes
├── Mjolnir.Cleanup            — existing, runs sweep() before reconcile
├── Mjolnir.Reconcile          [NEW] — rehydrate VMs from state + subvolumes, runs once at boot
├── Mjolnir.Health.Supervisor  [NEW] — registers probe/heal modules, exposes API
├── Mjolnir.Health.Monitor     [NEW] — periodic L0-L1 probe of every VM (30s interval)
├── Mjolnir.EventBus
├── Mjolnir.VMRegistry
├── Mjolnir.DormantRegistry    — existing, populated by Reconcile from state files
├── Mjolnir.VMSupervisor       — existing
├── Mjolnir.TaskSupervisor     — existing
└── Bandit HTTP Server
```

**Ordering matters.** `StateStore` → `Cleanup` (which now consults state to avoid wiping legit VMs) → `Reconcile` (which needs both) → `Health.Supervisor` (needs reconcile done so VMs are registered) → `VMSupervisor` (existing, hosts rehydrated VM GenServers).

---

## Reconcile state machine

Runs once on supervisor start, after `Cleanup`:

```
1. Load all /var/lib/mjolnir/state/*.json → desired = %{uuid => record}
2. List @vms/* subvolumes       → actual_vms
3. List @snapshots/* subvolumes → actual_snapshots

4. For each uuid in desired:
   case {desired[uuid].intent, uuid in actual_vms, dormant? in actual_snapshots}:
     {running, true, _}    → spawn VM GenServer in :resume mode
     {running, false, _}   → state is stale (subvolume gone); log WARN, mark stopped
     {dormant, _, true}    → register in DormantRegistry
     {dormant, _, false}   → state is stale (snapshot gone); log WARN, mark stopped
     {stopped, true, _}    → schedule GC of subvolume (24h grace)
     {stopped, false, _}   → delete state file

5. For each uuid in actual_vms but NOT in desired:
   → QUARANTINE. Log WARN. Do not auto-delete. Create /var/lib/mjolnir/quarantine/<uuid>.flag
   → Human must review and either adopt (create state) or delete.

6. For each uuid in actual_snapshots but NOT in any desired.dormant:
   → Orphan snapshot. Log INFO. Leave alone (could be user-created).
```

### VM GenServer `:resume` mode

The VM GenServer gets a new init path:

```elixir
def start_link({:resume, %StateStore.Record{} = record}) do
  # skip: BTRFS clone (subvolume exists)
  # skip: TAP allocation (recompute deterministic name; create if missing)
  # skip: guest agent injection (already in rootfs)
  # do:   start CH port against existing rootfs
  # do:   wait for guest agent ping
  # do:   L2 probe-and-reconfigure (option C):
  #       - probe hostname, SSH keys, Iroh node against record.identity
  #       - if probe fails OR hash mismatch → re-push configure_network/identity/iroh
  # do:   update StateStore with last_boot_at
end
```

---

## Probe & Heal catalog

### API shape

```elixir
defmodule Mjolnir.Health.Check do
  @type level :: 0..5
  @type status :: :ok | {:degraded, reason :: term()} | {:dead, reason :: term()}
  @callback level() :: level()
  @callback name() :: String.t()
  @callback probe(vm_id :: String.t()) :: status()
  @callback heal(vm_id :: String.t()) :: :ok | {:error, term()}
end
```

### Registered checks (in escalation order)

| Level | Module | Probe (exercise) | Heal (idempotent) |
|---|---|---|---|
| L0 | `Health.GuestAgentPing` | Send `{"op":"ping"}` over vsock; pong within 2s | — (diagnostic only; triggers L1) |
| L1 | `Health.VsockConnection` | Send round-trip test over `Vsock.Connection` GenServer | Stop GenServer, delete stale UDS, respawn |
| L1 | `Health.IrohConnection` | Request `get_iroh_status` over vsock; verify node answers a keepalive | Re-run `configure_iroh` with fresh ticket |
| L2 | `Health.GuestNetwork` | Exec `ping -c1 <gateway>` in guest; must succeed | Re-run `configure_network` in guest |
| L2 | `Health.GuestIdentity` | Hash `/etc/hostname` + `~/.ssh/authorized_keys` in guest; compare to record | Re-run `configure_identity` |
| L3 | `Health.GuestAgentProcess` | L0-L2 probes all fail despite L1 heals | Send serial-console `systemctl restart mjolnir-agent` |
| L4 | `Health.HypervisorAPI` | `GET /vm.info` via CH UDS; must respond in 2s | Graceful `vm.shutdown` + restart CH port; preserves rootfs |
| L5 | `Health.VMSubvolume` | `btrfs subvolume show @vms/<uuid>` + rw check | Respawn from base image; **destroys in-VM state** |

### Host-wide checks (in `Mjolnir.Health.Host`)

| Layer | Check | Probe | Heal |
|---|---|---|---|
| H0 | KVM module | `File.exists?("/dev/kvm")` + readable | `modprobe kvm kvm_intel` |
| H0 | Vsock module | `File.exists?("/dev/vhost-vsock")` | `modprobe vhost_vsock` |
| H0 | IP forward | `sysctl net.ipv4.ip_forward` == 1 | `sysctl -w net.ipv4.ip_forward=1` |
| H0 | NAT MASQUERADE | `iptables -t nat -C POSTROUTING ...` | Add rule |
| H0 | BTRFS root | `findmnt` matches expected UUID + rw | **FAIL FAST** — do not auto-remount; page human |
| H0 | Socket dir | touch test file | `mkdir -p` + chmod 0755 |
| H1 | Orphan sockets | Compare `*.sock` to VM registry | `rm` stale |
| H1 | Orphan TAPs | `ip link` vs. registry | `ip link del` stale |

### Public API

```elixir
# Read-only report
Mjolnir.Health.check(vm_id, opts \\ [])
# Probe-and-heal up to a level
Mjolnir.Health.heal(vm_id, max_level: 3)
# Nuclear option — always succeeds at making VM healthy (may destroy state)
Mjolnir.Health.nuke(vm_id)
# Host-wide
Mjolnir.Health.check_host()
Mjolnir.Health.heal_host()
```

**HTTP surface:**
- `GET /vms/<id>/health` → JSON report
- `POST /vms/<id>/heal` with `{"max_level": 3}` → heal report
- `POST /vms/<id>/nuke` → L5 rebuild
- `GET /health/host` → host-wide report

**CLI surface:**
- `mj doctor <id>` — pretty-printed check
- `mj doctor <id> --fix --max-level 3` — heal to level
- `(nuke: POST /api/vms/<id>/nuke — no mj command yet)` — escape hatch
- `mj doctor` — host-wide

### Monitor loop

`Mjolnir.Health.Monitor` runs L0-L1 probes on every registered VM every 30 seconds. On degraded/dead, escalates to L2 heal automatically. On L2+ failure, logs + emits EventBus event `{:vm_unhealthy, vm_id, report}` and stops escalating (human decides).

---

## Identity-on-resume policy

**Decision: option (c) — probe first, re-push on failure.**

On resume:
1. Establish vsock connection (required regardless).
2. Send `get_identity` probe that returns hash of `/etc/hostname` + `~/.ssh/authorized_keys` + iroh node ID.
3. Compare to `state.identity.*_hash`.
4. **Match** → done, VM is healthy.
5. **Mismatch or no response** → re-push `configure_network`, `configure_identity`, `configure_iroh`, update state with new hashes.

This costs ~50ms extra for healthy VMs (one probe round-trip), but auto-recovers from guest drift (e.g. user manually edited hostname, SSH keys got nuked by cloud-init, iroh node daemon died and got a new ID).

---

## Chaos scenarios

Ordered by implementation + pass order. Each is an ExUnit test under `test/chaos/` with `@moduletag :chaos`. All run against the prod server via SSH + HTTP tunnel.

### Test tagging

- `@moduletag :chaos` — all chaos tests; excluded by default (`ExUnit.configure(exclude: [:chaos])` in `test/test_helper.exs`). Run with `mix test --only chaos`.
- `@moduletag :destructive` — scenarios that cause observable host-wide downtime or external disruption (server reboot, network partitions, full disk fills). **Additive**: `mix test --only chaos` skips these too. Opt-in via `mix test --only chaos --include destructive`.

### Scenario matrix

| # | Tags | Scenario | Trigger | Assertion |
|---|---|---|---|---|
| 1 | `:chaos` | Mjolnir restart | `ssh mjolnir systemctl restart mjolnir` | Pre-existing VM UUIDs reappear; `mj exec <id> "uname -a"` succeeds on each; IPs unchanged |
| 2 | `:chaos` | BEAM SIGKILL | `ssh mjolnir pkill -9 beam.smp` | Systemd restarts mjolnir; scenario 1 assertions |
| 3 | `:chaos, :destructive` | Server reboot | `ssh mjolnir systemctl reboot`; wait for ssh | Scenario 1 assertions after boot. ~60s host downtime. |
| 4 | `:chaos` | CH child SIGKILL (one VM) | `pkill -9 -f "cloud-hypervisor.*<uuid>"` | That VM's `GenServer` exits → `Reconcile` or `Health.Monitor` rebuilds it; other VMs untouched |
| 5 | `:chaos, :destructive` | Iroh rot | nftables drop on iroh relay egress for 60s, then restore | `Health.IrohConnection` reports `:dead`; `heal` restores; inference works again. Affects all VMs' external connectivity for the drop window. |
| 6 | `:chaos` | Vsock wedge | Truncate UDS file mid-flight | `Health.VsockConnection` detects; heal reconnects |
| 7 | `:chaos` | TAP down | `ip link set mj-<uuid> down` | `Health.GuestNetwork` probe fails; heal brings up |
| 8 | `:chaos, :destructive` | NAT wipe | `iptables -t nat -F` | `Health.Host` detects; heal reinstalls; guest egress works. Breaks egress for every VM until heal lands. |
| 9 | `:chaos, :destructive` | Disk full | `dd if=/dev/zero of=/var/lib/mjolnir/btrfs/fill bs=1M` until full | No silent data loss; fail-fast on spawn; existing VMs keep running until they write. Risks real data loss in adjacent services. |
| 10 | `:chaos, :destructive` | BTRFS readonly | `mount -o remount,ro /var/lib/mjolnir/btrfs` | `Health.Host` alerts; spawn rejected with clear error. All spawns blocked until remount rw. |

### Test harness skeleton

`test/chaos/chaos_helpers.ex` (new):

```elixir
defmodule Mjolnir.Chaos.Helpers do
  @host System.get_env("MJOLNIR_HOST", "root@45.76.77.97")

  def ssh(cmd), do: System.cmd("ssh", [@host, cmd])
  def api(method, path, body \\ nil), do: # ssh-wrapped curl, same pattern as Justfile

  def spawn_vm(opts \\ []), do: api("POST", "/vms", Jason.encode!(opts))
  def vm_health(uuid), do: api("GET", "/vms/#{uuid}/health")
  def wait_for_mjolnir_up(timeout \\ 60_000), do: # poll /health until 200 or timeout

  def chaos(action), do: # dispatch to named chaos actions
end
```

`test/chaos/restart_test.exs` (scenario 1):

```elixir
defmodule Mjolnir.Chaos.RestartTest do
  use ExUnit.Case, async: false
  @moduletag :chaos
  import Mjolnir.Chaos.Helpers

  test "mjolnir restart preserves VMs" do
    {:ok, vm} = spawn_vm(base_image: "ubuntu-24.04")
    assert {:ok, _} = exec(vm.id, "echo hi")

    chaos(:restart_mjolnir)
    wait_for_mjolnir_up()

    assert {:ok, %{"id" => id}} = api("GET", "/vms/#{vm.id}")
    assert id == vm.id
    assert {:ok, _} = exec(vm.id, "echo still_alive")
  end
end
```

Run with: `mix test --only chaos` (skipped by default; `chaos` tag added to `ExUnit.configure(exclude: [:integration, :chaos])` in `test/test_helper.exs`).

---

## Implementation order (Option B within C)

1. **`Mjolnir.StateStore`** — JSON file CRUD + ETS cache + atomic write. Unit tests in `test/state_store_test.exs`. No runtime integration yet.
2. **Hook StateStore into `VM` GenServer lifecycle** — write on spawn, update on state transitions, delete on stop. `mix test` still green.
3. **`Mjolnir.Reconcile`** — boot-time rehydration. Insert into supervision tree. Manual smoke test: spawn VM, `restart mjolnir`, observe VM reappear.
4. **Scenario 1 chaos test** — mjolnir restart. Should pass after step 3.
5. **Scenario 2 + 3** — BEAM SIGKILL + server reboot. May require systemd unit tweaks (`Restart=always`, `RestartSec`).
6. **`Mjolnir.Health.Check` behaviour + L0/L1 modules** — vsock + guest-agent probes.
7. **Scenario 4 + 6** — CH SIGKILL + vsock wedge. Uses L1 heal.
8. **L2-L3 modules** — guest network, identity, agent process.
9. **Scenario 5 (Iroh rot)** — the original motivating case.
10. **`Mjolnir.Health.Host` + scenarios 7, 8, 10** — host-wide checks.
11. **`Mjolnir.Health.Monitor` periodic loop** — plus EventBus integration.
12. **Scenario 9 (disk full)** — graceful degradation story.

---

## Followups

### Vsock-closes-during-exec when TAP is admin-down (found 2026-04-21)

Uncovered by the scenario 7 chaos test (`test/chaos/tap_down_test.exs`,
currently skipped). Sequence:

1. `ip link set mj-<uuid> down` on the host.
2. Next `VM.exec/2` over vsock — the L2 `GuestNetwork` probe itself —
   gets `{:tcp_closed, Port}` on the vsock UDS within ~100ms, even
   though vsock is a separate transport from the TAP/virtio-net link.
3. `Mjolnir.Vsock.Connection` terminates with `:connection_closed`
   mid-`GenServer.call`; the VM GenServer re-raises the exit; terminate
   is non-`:normal` so state is preserved and Reconcile tries to resume.
4. Resume calls `Mjolnir.Network.create_tap/1` → `ip tuntap add` →
   `EBUSY` because the admin-down interface still exists. Boot fails,
   cleanup runs, next Reconcile tick eventually succeeds.

Two root causes to fix, each fixable independently:

- **a.** Vsock should survive TAP admin-down. Find what cross-links the
  two — likely either Cloud Hypervisor reacting to virtio-net carrier
  loss by tearing down the vsock backend, or the guest agent closing
  its vsock listener when it detects carrier loss. Fix upstream.
- **b.** `Network.create_tap/1` must tolerate a pre-existing interface.
  Either make it idempotent (detect existing, skip create, re-assert
  link up + route), or have Reconcile's resume path call
  `Mjolnir.Network.repair_tap/1` instead when the TAP name already
  exists on the host.

Until both land, the L2 `GuestNetwork` probe is strong enough to catch
NAT wipe and guest-side route drift, but the healing path for admin-down
TAPs will trigger the cascade.

## Open questions

1. **Systemd unit hardening.** Does `mjolnir.service` currently have `Restart=always`? If not, scenario 2 (BEAM SIGKILL → systemd restart) can't pass. Confirm and fix before step 5.
2. **Quarantine policy.** When reconcile finds an orphan subvolume (subvolume exists, no state file), how long before auto-GC? Proposal: 7 days + human flag, never silent.
3. **In-flight spawn crash.** If BEAM dies *during* a spawn (subvolume half-created, TAP up, CH not yet started), how does reconcile handle it? Proposal: state file is written *only after* CH is up and guest agent pinged; a subvolume with no state file is always quarantine, not resume.
4. **State schema versioning.** Add `"schema_version": 1` to JSON; reconcile rejects unknown versions with clear error. Migrations via explicit one-shot Mix task.
5. **Chaos test blast radius.** Scenario 3 (server reboot) takes the server down for ~60s — during which `just` commands and other sessions will fail. Gate behind an extra `--include destructive` flag?
6. **PTY session continuity across restart.** If a user has an active PTY attached via Iroh, a mjolnir restart drops it. Accept this for now, or scope a "PTY session resume" story? (Leaning accept; PTY is inherently session-scoped.)
