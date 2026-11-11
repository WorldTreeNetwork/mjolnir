---
spike_id: aie-occupancy-lock
hypothesis_id: aie-occupancy-lock
source_synthesis: null
run_at: 2026-11-11T05:16:40Z
time_spent_min: 40
verdict: go
version-pinned: Framework5070 Arch 7.2.14-arch1-1, amdxdna, XRT 2.21.75, NPU6/Krackan c3:00.1 /dev/accel/accel0, ironlab 0.1.0 (target/debug) occupancy.rs protocol, Python 3.14.4 throwaway sidecar
---

# Spike: sidecar and ironlab share one flock through timeout, cancel, and restart

## Claim Tested

sidecar and `ironlab` share one flock through timeout, cancel, and restart

Exact line from `openspec/changes/add-aie-host-sidecar/design.md`. Architecture: same IRON Lab occupancy flock identity; try-lock then admit under deadline then load or release; hold from immediately before catalog-design load until the XRT worker is reaped and the device is quiescent; timeout and cancel wait for quiescence before releasing; restart with a live worker fails closed.

## Minimal Test

Hypothesis: cooperating sidecar + ironlab exclusive flock serializes occupancy through timeout, cancel, and restart.

Version pinned to: Framework5070 Arch, amdxdna, XRT 2.21.75, `ironlab-device` occupancy.rs as cited.

Setup: throwaway Python sidecar (`sidecar.py`) using libc `flock` `LOCK_EX|LOCK_NB` on the same `$XDG_RUNTIME_DIR/ironlab/occupancy.lock` path as `ironlab`, writing `occupancy.json` `{pid, bundle, started_unix, exe}`. Simulated XRT worker is `sleep`. No production Elixir/sidecar modules, no systemd units, no guest xclbins, no VM.

Action (all three required for go):

1. Share identity: `ironlab load` holds → sidecar try-lock Occupied. Reverse: sidecar holds → `ironlab load` refused. Quote the lock path both used.
2. Timeout/cancel wait for quiescence: sidecar holds flock, starts worker, request times out while worker is alive; second process fails to claim until worker reaped and flock released.
3. Restart with a live worker fails closed: SIGKILL sidecar while child lives. New try-lock must refuse until the worker is reaped (cooperating check: worker inherits the lock fd). Control: without inherit, occupancy.rs dead-pid steal admits a second claim while the orphan lives.

Assertion: all three sub-claims empirically true → go.

## Evidence

Lock path both processes used: `/run/user/1000/ironlab/occupancy.lock` (`XDG_RUNTIME_DIR=/run/user/1000`). `ironlab status` deserialized the sidecar-written JSON (same schema as occupancy.rs).

- `evidence.log` — full command transcript, 11 PASS / 0 FAIL
- `evidence.code` / `sidecar.py` — throwaway sidecar
- `repro-command.sh` — exact suite

### 1. Share identity / second run does not clobber

`ironlab load` of `validate.xclbin` claimed pid 540966 (XRT `load_axlf: Operation not supported` as expected on XDNA; occupancy still held). Sidecar try-lock:

```
TRY occupied NPU is occupied by pid 540966 (bundle '.../validate.xclbin', started_unix=1794374184)
lock=/run/user/1000/ironlab/occupancy.lock
```

Reverse: sidecar hold pid 541004, bundle `sidecar-vs-ironlab`. Real `ironlab load`:

```
load refused: NPU is occupied by pid 541004 (bundle Some("sidecar-vs-ironlab"), started_unix=1794374185)
```

`ironlab status` while sidecar held: `occupancy: pid 541004 bundle Some("sidecar-vs-ironlab")`. Second Python process also Occupied. After SIGTERM + quiescence, try-lock admitted.

### 2. Timeout / cancel wait for quiescence

Timeout: request expired at 0.8s with worker 541066 still alive (`expired=worker=541066 alive=True`). Probe during that window:

```
TRY occupied NPU is occupied by pid 541063 (bundle 'sidecar-timeout', ...)
```

Flock released only after worker reaped (~5s); then try-lock admitted. Releasing the flock at timeout while the worker lived did **not** happen.

Cancel: SIGTERM kills the worker then waits before `LOCK_UN`. This run the worker exited fast enough that the immediate probe saw both gone (fail-closed completion, not a mid-wait sample). The timeout case is the live-worker hold.

### 3. Restart with a live worker fails closed

SIGKILL sidecar 541259; Drop did not run; `occupancy.json` still named the dead pid. Worker 541262 still alive **and inherited the lock fd**. New sidecar try-lock:

```
TRY occupied NPU is occupied by pid 0 (bundle 'flock-held-no-live-json', started_unix=0)
```

`read_state()` cleared the dead-pid JSON (occupancy.rs steal path would then `flock_exclusive_block`). Cooperating try-lock refuses while the flock is held even with no live JSON. After the orphan worker exited, try-lock admitted.

Control (not inherit): SIGKILL sidecar 541506, worker 541509 alive, flock released by kernel. Try-lock **succeeded** (`TRY claimed pid=541545 … bundle='probe-naive-steal'`) while the orphan lived. That is occupancy.rs dead-pid steal without a second holder of the fd. Production sidecar **must** keep the flock fd alive in the worker (or refuse on a persisted live-worker pid after a successful try-lock). Hardware will not serialize (`docs/occupancy-findings.md`: two concurrent `NPUKernel()` both succeed), so “accel busy” is not a substitute.

Lock is advisory: a host `just hello` that never takes this flock can still clobber. This spike only coordinates cooperating IRON entry points (`ironlab load` + sidecar using occupancy.rs identity).

## Verdict: go

All three sub-claims held on Framework5070 against the real `ironlab` binary and a throwaway sidecar on the same `occupancy.lock`. Shared identity is the IRON path `$XDG_RUNTIME_DIR/ironlab/{occupancy.lock,occupancy.json}`. Timeout keeps the flock until the worker is reaped. Restart fails closed **only if** the cooperating sidecar inherits the lock fd to the XRT worker (or an equivalent live-worker check). Parent-only flock + occupancy.rs steal is no-go for restart; that failure mode was reproduced as the control, not as the cooperating protocol.

No synthesis.md to update. `add-aie-host-sidecar/design.md` left unverified for the caller to mark `go`.
