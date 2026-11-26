#!/usr/bin/env python3
"""UDP proxy that drops packets: lossy.py <listen-ip:port> <edge-ip:port> <loss-to-client> <loss-to-edge> [--burst SECONDS]
The edge advertises the listen address as its ICE candidate (EDGE_ADVERTISE), so the browser's media
passes here. Each direction drops a random fraction. --burst drops every datagram for SECONDS after
the first packet, then returns to the fractional loss. Prints counts on SIGTERM."""
import random, selectors, signal, socket, sys, time
args = sys.argv[1:]
burst = None
burst_after = 0.0
if "--burst-after" in args:
    i = args.index("--burst-after")
    burst_after = float(args[i + 1])
    del args[i:i + 2]
if "--burst" in args:
    i = args.index("--burst")
    burst = float(args[i + 1])
    del args[i:i + 2]
lh, lp = args[0].rsplit(':', 1); eh, ep = args[1].rsplit(':', 1)
to_client, to_edge = float(args[2]), float(args[3])
burst_start = None
burst_until = None
front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); front.bind((lh, int(lp)))
backs, owner = {}, {}
sel = selectors.DefaultSelector(); sel.register(front, selectors.EVENT_READ, None)
n = {'to_edge': 0, 'to_edge_dropped': 0, 'to_client': 0, 'to_client_dropped': 0}
def done(*_):
    print(n, flush=True); sys.exit(0)
signal.signal(signal.SIGTERM, done); signal.signal(signal.SIGINT, done)
while True:
    for key, _ in sel.select():
        sock = key.fileobj
        data, src = sock.recvfrom(65535)
        if burst is not None and burst_start is None and sock is front:
            burst_start = time.time() + burst_after
            burst_until = burst_start + burst
        in_burst = burst_start is not None and burst_start <= time.time() < burst_until
        if sock is front:
            b = backs.get(src)
            if b is None:
                b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); b.bind((lh, 0)); backs[src] = b; owner[b] = src
                sel.register(b, selectors.EVENT_READ, None)
            n['to_edge'] += 1
            if in_burst or random.random() < to_edge:
                n['to_edge_dropped'] += 1; continue
            b.sendto(data, (eh, int(ep)))
        else:
            n['to_client'] += 1
            if in_burst or random.random() < to_client:
                n['to_client_dropped'] += 1; continue
            front.sendto(data, owner[sock])
