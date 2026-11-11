#!/usr/bin/env python3
"""Throwaway occupancy sidecar for spike aie-occupancy-lock. Not production.

Mirrors ironlab-device occupancy.rs:
  dir: $XDG_RUNTIME_DIR/ironlab else /tmp/ironlab-<euid>
  occupancy.lock: libc flock LOCK_EX | LOCK_NB
  occupancy.json: {pid, bundle, started_unix, exe}

Same-process second flock succeeds (process-wide). A second process is
refused. Dead pid in the state file is steal/clear.

Cooperating restart: the XRT worker inherits the lock fd (pass_fds).
SIGKILL of the sidecar then leaves the flock held until the worker is
reaped. occupancy.rs Drop does not run on SIGKILL; without inherit,
kernel flock release + dead-pid steal would admit a second design
while the orphan worker lives.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def occupancy_dir() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return Path(runtime) / "ironlab"
    return Path("/tmp") / f"ironlab-{os.geteuid()}"


def lock_path() -> Path:
    return occupancy_dir() / "occupancy.lock"


def state_path() -> Path:
    return occupancy_dir() / "occupancy.json"


def pid_alive(pid: int) -> bool:
    return Path(f"/proc/{pid}").exists()


def read_state() -> dict | None:
    path = state_path()
    if not path.exists():
        return None
    try:
        text = path.read_text()
    except OSError:
        return None
    if not text.strip():
        return None
    try:
        state = json.loads(text)
    except json.JSONDecodeError as e:
        raise SystemExit(f"lock state is corrupt: {e}")
    if not pid_alive(int(state["pid"])):
        try:
            path.unlink()
        except OSError:
            pass
        return None
    return state


def write_state(bundle: str | None) -> dict:
    exe = None
    try:
        exe = os.readlink("/proc/self/exe")
    except OSError:
        exe = sys.executable
    state = {
        "pid": os.getpid(),
        "bundle": bundle,
        "started_unix": int(time.time()),
        "exe": exe,
    }
    path = state_path()
    path.write_text(json.dumps(state, indent=2) + "\n")
    return state


def clear_state_if_ours(pid: int) -> None:
    path = state_path()
    try:
        text = path.read_text()
        state = json.loads(text)
        if int(state.get("pid", -1)) == pid:
            path.unlink()
    except (OSError, json.JSONDecodeError, TypeError):
        pass


class OccupancyGuard:
    """Holds LOCK_EX on occupancy.lock. Close/unlock on release()."""

    def __init__(self, fd: int, lockfile, state: dict):
        self.fd = fd
        self._lockfile = lockfile
        self.state = state
        self._released = False

    def release(self) -> None:
        if self._released:
            return
        clear_state_if_ours(self.state["pid"])
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            self._lockfile.close()
        except OSError:
            pass
        self._released = True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.release()
        return False


def try_claim(bundle: str | None, steal_block: bool = False) -> OccupancyGuard:
    """Try-lock. On EWOULDBLOCK: Occupied if live state, else optional steal.

    steal_block=False (sidecar try-lock): refuse while the flock is held,
    even if occupancy.json pid is dead (orphan worker inherited the fd).
    steal_block=True matches occupancy.rs claim() stale-lock steal.
    """
    d = occupancy_dir()
    d.mkdir(parents=True, exist_ok=True)
    lockfile = open(lock_path(), "a+b")
    fd = lockfile.fileno()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        state = read_state()
        if state is not None:
            lockfile.close()
            raise Occupied(
                int(state["pid"]),
                state.get("bundle"),
                int(state.get("started_unix", 0)),
            )
        if not steal_block:
            lockfile.close()
            raise Occupied(0, "flock-held-no-live-json", 0)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as e:
            lockfile.close()
            raise SystemExit(f"steal flock: {e}")
    state = write_state(bundle)
    return OccupancyGuard(fd, lockfile, state)


class Occupied(Exception):
    def __init__(self, pid: int, bundle, since_unix: int):
        self.pid = pid
        self.bundle = bundle
        self.since_unix = since_unix
        super().__init__(
            f"NPU is occupied by pid {pid} (bundle {bundle!r}, started_unix={since_unix})"
        )


def spawn_worker(seconds: int, inherit_lock_fd: int | None, marker: Path) -> subprocess.Popen:
    """Simulated XRT worker: sleep, optionally inherit the occupancy lock fd."""
    marker.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    cmd = [
        sys.executable,
        "-c",
        (
            "import os,sys,time;"
            f"open({str(marker)!r},'w').write(str(os.getpid())+'\\n');"
            "sys.stdout.flush();"
            f"time.sleep({int(seconds)});"
            f"os.path.exists({str(marker)!r}) and os.remove({str(marker)!r})"
        ),
    ]
    if inherit_lock_fd is None:
        return subprocess.Popen(cmd, env=env, close_fds=True)
    os.set_inheritable(inherit_lock_fd, True)
    return subprocess.Popen(
        cmd,
        env=env,
        close_fds=True,
        pass_fds=(inherit_lock_fd,),
    )


def wait_marker(marker: Path, timeout: float = 5.0) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker.exists():
            return int(marker.read_text().strip())
        time.sleep(0.05)
    raise SystemExit(f"worker marker not written: {marker}")


def cmd_paths(_args) -> int:
    print(f"occupancy_dir={occupancy_dir()}")
    print(f"lock={lock_path()}")
    print(f"state={state_path()}")
    st = None
    try:
        st = read_state()
    except SystemExit as e:
        print(f"state_corrupt={e}")
        return 1
    print(f"live_state={json.dumps(st)}")
    return 0


def cmd_try(args) -> int:
    bundle = args.bundle
    try:
        guard = try_claim(bundle, steal_block=args.steal)
    except Occupied as e:
        print(f"TRY occupied {e}")
        print(f"lock={lock_path()}")
        return 1
    print(f"TRY claimed pid={guard.state['pid']} lock={lock_path()} bundle={bundle!r}")
    if args.hold:
        print("holding; SIGTERM releases after wait")
        stop = {"go": True}

        def _term(_s, _f):
            stop["go"] = False

        signal.signal(signal.SIGTERM, _term)
        signal.signal(signal.SIGINT, _term)
        while stop["go"]:
            time.sleep(0.1)
    guard.release()
    print("TRY released")
    return 0


def cmd_hold(args) -> int:
    """Claim, start worker, hold until SIGTERM/SIGINT then wait for quiescence."""
    bundle = args.bundle
    try:
        guard = try_claim(bundle, steal_block=False)
    except Occupied as e:
        print(f"HOLD occupied {e}", flush=True)
        return 1
    inherit = guard.fd if args.inherit else None
    marker = Path(args.marker)
    worker = spawn_worker(args.worker_sec, inherit, marker)
    wpid = wait_marker(marker)
    print(
        f"HOLD claimed pid={os.getpid()} worker={wpid} inherit={bool(args.inherit)} "
        f"lock={lock_path()} bundle={bundle!r}",
        flush=True,
    )
    if args.ready:
        Path(args.ready).write_text(f"{os.getpid()} {wpid}\n")
    # Flag-only handlers: Popen.wait() is not reentrant with the main wait loop.
    stop = {"cancel": False}

    def on_stop(_s, _f):
        stop["cancel"] = True

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    t0 = time.time()
    while True:
        if args.self_kill_after is not None and (time.time() - t0) >= args.self_kill_after:
            print(f"HOLD self-SIGKILL pid={os.getpid()} worker still {wpid}", flush=True)
            os.kill(os.getpid(), signal.SIGKILL)
        if stop["cancel"]:
            print(f"HOLD cancel/timeout: wait for worker {wpid} before flock release", flush=True)
            if worker.poll() is None and args.kill_worker_on_cancel:
                worker.send_signal(signal.SIGTERM)
            rc = worker.wait()
            if marker.exists():
                marker.unlink()
            guard.release()
            print(f"HOLD released after quiescence rc={rc}", flush=True)
            return 0
        rc = worker.poll()
        if rc is not None:
            if marker.exists():
                marker.unlink()
            guard.release()
            print(f"HOLD worker exited rc={rc}; flock released", flush=True)
            return 0
        time.sleep(0.05)


def cmd_timeout(args) -> int:
    """Request times out while worker is alive; flock stays until worker reaped."""
    bundle = args.bundle
    try:
        guard = try_claim(bundle, steal_block=False)
    except Occupied as e:
        print(f"TIMEOUT occupied {e}", flush=True)
        return 1
    inherit = guard.fd if args.inherit else None
    marker = Path(args.marker)
    worker = spawn_worker(args.worker_sec, inherit, marker)
    wpid = wait_marker(marker)
    print(
        f"TIMEOUT claimed pid={os.getpid()} worker={wpid} lock={lock_path()}",
        flush=True,
    )
    if args.ready:
        Path(args.ready).write_text(f"{os.getpid()} {wpid}\n")
    time.sleep(args.request_timeout)
    expired = occupancy_dir() / "timeout-expired.flag"
    expired.write_text(f"worker={wpid} alive={pid_alive(wpid)}\n")
    print(
        f"TIMEOUT request expired; worker_alive={pid_alive(wpid)} "
        f"flock_still_held=yes (not releasing yet)",
        flush=True,
    )
    # Cooperate: do not unlock while worker lives.
    rc = worker.wait()
    if marker.exists():
        marker.unlink()
    print(f"TIMEOUT worker reaped rc={rc}; releasing flock", flush=True)
    guard.release()
    print("TIMEOUT released after quiescence", flush=True)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("paths")
    s.set_defaults(func=cmd_paths)

    s = sub.add_parser("try")
    s.add_argument("--bundle", default="sidecar-try")
    s.add_argument("--hold", action="store_true")
    s.add_argument("--steal", action="store_true", help="blocking steal like occupancy.rs")
    s.set_defaults(func=cmd_try)

    s = sub.add_parser("hold")
    s.add_argument("--bundle", default="sidecar-hold")
    s.add_argument("--worker-sec", type=int, default=8)
    s.add_argument("--marker", default="/tmp/aie-occupancy-lock-worker.pid")
    s.add_argument("--inherit", action="store_true", default=True)
    s.add_argument("--no-inherit", action="store_false", dest="inherit")
    s.add_argument("--kill-worker-on-cancel", action="store_true", default=True)
    s.add_argument("--self-kill-after", type=float, default=None)
    s.add_argument("--ready", default="")
    s.set_defaults(func=cmd_hold)

    s = sub.add_parser("timeout")
    s.add_argument("--bundle", default="sidecar-timeout")
    s.add_argument("--worker-sec", type=int, default=6)
    s.add_argument("--request-timeout", type=float, default=1.0)
    s.add_argument("--marker", default="/tmp/aie-occupancy-lock-worker.pid")
    s.add_argument("--inherit", action="store_true", default=True)
    s.add_argument("--ready", default="")
    s.set_defaults(func=cmd_timeout)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
