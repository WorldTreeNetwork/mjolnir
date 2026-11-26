#!/usr/bin/env python3
"""UDP ceiling between two hosts. No install.

  udp-bench.py sink PORT SECONDS
  udp-bench.py blast HOST PORT SECONDS MBPS
Prints bytes and an approximate loss when the blast size is known.
"""
import socket, sys, time

def sink():
    port, seconds = int(sys.argv[2]), float(sys.argv[3])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", port))
    s.settimeout(0.5)
    end = time.time() + seconds
    n = 0
    b = 0
    while time.time() < end:
        try:
            data, _ = s.recvfrom(65535)
        except socket.timeout:
            continue
        n += 1
        b += len(data)
    print(f"SINK packets={n} bytes={b} seconds={seconds}")

def blast():
    host, port = sys.argv[2], int(sys.argv[3])
    seconds, mbps = float(sys.argv[4]), float(sys.argv[5])
    payload = b"x" * 1200
    per_s = max(1, int(mbps * 1_000_000 / 8 / len(payload)))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    end = time.time() + seconds
    sent = 0
    while time.time() < end:
        burst = time.time() + 0.05
        goal = int(per_s * 0.05)
        for _ in range(goal):
            s.sendto(payload, (host, port))
            sent += 1
        left = burst - time.time()
        if left > 0:
            time.sleep(left)
    print(f"BLAST sent={sent} bytes={sent*len(payload)} mbps={mbps} seconds={seconds}")

if sys.argv[1] == "sink":
    sink()
elif sys.argv[1] == "blast":
    blast()
else:
    sys.exit(2)
