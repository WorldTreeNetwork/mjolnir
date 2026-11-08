#!/usr/bin/env python3
"""Throwaway AIE sidecar for spike aie-npu-path. Not production.

Binds 10.200.0.1 (dummy-mjolnir). Holds /dev/accel/accel0. POST /hello
runs the IRON vector-add on the host NPU and returns JSON.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BIND = os.environ.get("AIE_SPIKE_BIND", "10.200.0.1")
PORT = int(os.environ.get("AIE_SPIKE_PORT", "7422"))
ACCEL = Path("/dev/accel/accel0")
FW = Path("/sys/class/accel/accel0/device/fw_version")
HELLO = Path(
    os.environ.get(
        "AIE_HELLO",
        "/home/dorje/work/AI/parakeet-aie/examples/hello-vector-add/vector_add.py",
    )
)
LAB = HELLO.resolve().parents[2]
VENV_PY = LAB / ".venv/bin/python"


def _fw() -> str:
    try:
        return FW.read_text().strip()
    except OSError as e:
        return f"unreadable:{e}"


class Handler(BaseHTTPRequestHandler):
    accel_fd = None

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path not in ("/", "/health"):
            self._send(404, {"error": "not_found"})
            return
        self._send(
            200,
            {
                "ok": True,
                "accel": str(ACCEL),
                "accel_open": Handler.accel_fd is not None,
                "fw_version": _fw(),
                "pid": os.getpid(),
            },
        )

    def do_POST(self) -> None:
        if self.path != "/hello":
            self._send(404, {"error": "not_found"})
            return
        t0 = time.monotonic()
        env = os.environ.copy()
        mlir_bin = LAB / "third_party/mlir-aie/install/bin"
        env["PATH"] = f"{mlir_bin}:{LAB / '.venv/bin'}:{env.get('PATH', '')}"
        try:
            proc = subprocess.run(
                [str(VENV_PY), str(HELLO)],
                cwd=str(LAB),
                env=env,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except subprocess.TimeoutExpired:
            self._send(504, {"ok": False, "error": "timeout"})
            return
        dt_ms = int((time.monotonic() - t0) * 1000)
        match = "Match: True" in proc.stdout or "NPU vector add: PASS" in proc.stdout
        ok = proc.returncode == 0 and match
        self._send(
            200 if ok else 500,
            {
                "ok": ok,
                "match": match or ("NPU execution: OK" in proc.stdout),
                "returncode": proc.returncode,
                "dt_ms": dt_ms,
                "fw_version": _fw(),
                "stdout_tail": proc.stdout[-4000:],
                "stderr_tail": proc.stderr[-2000:],
            },
        )

    def log_message(self, fmt: str, *args) -> None:
        print(f"sidecar: {self.address_string()} {fmt % args}", flush=True)


def main() -> None:
    Handler.accel_fd = os.open(ACCEL, os.O_RDWR)
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"aie-npu-path sidecar {BIND}:{PORT} fd={Handler.accel_fd} fw={_fw()}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
