#!/usr/bin/env python3
"""UDP proxy that drops packets: lossy.py <listen-ip:port> <edge-ip:port> <loss-to-client> <loss-to-edge> [--burst SECONDS] [--burst-dir edge|client|both]
The edge advertises the listen address as its ICE candidate (EDGE_ADVERTISE), so the browser's media
passes here. Each direction drops a random fraction. --burst drops datagrams for SECONDS after
the first packet toward the edge. --burst-dir selects that blackout's leg (default both).
Front packets are toward the edge. Back packets are toward the client. Prints counts on SIGTERM."""
import random, selectors, signal, socket, sys, time
args = sys.argv[1:]
burst = None
burst_after = 0.0
burst_dir = "both"
suppress = "--suppress-delta" in args
if suppress:
    args.remove("--suppress-delta")
if "--burst-after" in args:
    i = args.index("--burst-after")
    burst_after = float(args[i + 1])
    del args[i:i + 2]
if "--burst" in args:
    i = args.index("--burst")
    burst = float(args[i + 1])
if "--burst-dir" in args:
    i = args.index("--burst-dir")
    burst_dir = args[i + 1]
    if burst_dir not in ("edge", "client", "both"):
        sys.exit("burst-dir must be edge, client, or both")
    del args[i:i + 2]
lh, lp = args[0].rsplit(':', 1); eh, ep = args[1].rsplit(':', 1)
to_client, to_edge = float(args[2]), float(args[3])
burst_start = None
burst_until = None
front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); front.bind((lh, int(lp)))
backs, owner = {}, {}
sel = selectors.DefaultSelector(); sel.register(front, selectors.EVENT_READ, None)
n = {'to_edge': 0, 'to_edge_dropped': 0, 'to_client': 0, 'to_client_dropped': 0,
     'delta_dropped': 0, 'rtx_dropped': 0}
media_pt = None
drop_seqs = set()
delta_ts = None
delta_open = False
seen_key = False
warmup_at = None
def rtp_parse(data):
    if len(data) < 12 or (data[0] >> 6) != 2:
        return None
    cc = data[0] & 0x0F
    ext = (data[0] >> 4) & 1
    pt = data[1] & 0x7F
    seq = int.from_bytes(data[2:4], 'big')
    ts = int.from_bytes(data[4:8], 'big')
    off = 12 + cc * 4
    if ext:
        if len(data) < off + 4:
            return None
        words = int.from_bytes(data[off + 2:off + 4], 'big')
        off += 4 + words * 4
    if off > len(data):
        return None
    ssrc = int.from_bytes(data[8:12], 'big')
    marker = (data[1] & 0x80) != 0
    return pt, seq, ts, ssrc, marker, data[off:]
# SRTP hides the VP8 P bit. The clear RTP header still names a frame: one timestamp
# on the video SSRC. After one completed frame, the next timestamp is a delta.
# Its sequence numbers stay dropped, and every other payload type (RTX) is dropped
# for a short window so a retransmission cannot fill that hole. Later video
# timestamps are forwarded.
video = {}
chosen = None
rtx_until = 0.0
completed = 0
def suppress_delta(data):
    global media_pt, delta_ts, delta_open, chosen, rtx_until, completed
    parsed = rtp_parse(data)
    if parsed is None:
        return False
    pt, seq, ts, ssrc, marker, payload = parsed
    st = video.setdefault(ssrc, {"bytes": 0, "pt": pt, "ts": None})
    st["bytes"] += len(data)
    if chosen is None and warmup_at is not None and time.time() >= warmup_at and video:
        chosen = max(video, key=lambda s: video[s]["bytes"])
        media_pt = video[chosen]["pt"]
        print(f"media_ssrc={chosen} media_pt={media_pt}", flush=True)
    if time.time() < rtx_until and media_pt is not None and pt != media_pt:
        n["rtx_dropped"] += 1
        return True
    if chosen is None or ssrc != chosen:
        return False
    if seq in drop_seqs:
        n["delta_dropped"] += 1
        return True
    new_frame = st["ts"] is not None and ts != st["ts"]
    if (not delta_open and delta_ts is None and completed >= 1 and new_frame):
        delta_open = True
        delta_ts = ts
        rtx_until = time.time() + 0.8
        print(f"delta_suppress start ts={ts} seq={seq} epoch={time.time():.3f}", flush=True)
    if delta_open and ts == delta_ts:
        drop_seqs.add(seq)
        n["delta_dropped"] += 1
        if marker:
            delta_open = False
            seqs = sorted(drop_seqs)
            print(f"delta_suppress range {seqs[0]}-{seqs[-1]} n={len(seqs)} epoch={time.time():.3f}", flush=True)
        return True
    if st["ts"] != ts:
        st["ts"] = ts
    if marker:
        completed += 1
    return False
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
            print(f"burst_window start={burst_start:.3f} until={burst_until:.3f} dir={burst_dir}", flush=True)
        in_burst = burst_start is not None and burst_start <= time.time() < burst_until
        if sock is front:
            if suppress and warmup_at is None:
                warmup_at = time.time() + 1.0
                print(f"delta_warmup until={warmup_at:.3f}", flush=True)
            b = backs.get(src)
            if b is None:
                b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); b.bind((lh, 0)); backs[src] = b; owner[b] = src
                sel.register(b, selectors.EVENT_READ, None)
            n['to_edge'] += 1
            if suppress and suppress_delta(data):
                n['to_edge_dropped'] += 1; continue
            if (in_burst and burst_dir in ("edge", "both")) or random.random() < to_edge:
                n['to_edge_dropped'] += 1; continue
            b.sendto(data, (eh, int(ep)))
        else:
            n['to_client'] += 1
            if (in_burst and burst_dir in ("client", "both")) or random.random() < to_client:
                n['to_client_dropped'] += 1; continue
            front.sendto(data, owner[sock])
