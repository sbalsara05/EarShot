#!/usr/bin/env python3
"""Minimal iPad stand-in for firmware bring-up: connect to a clip's Wi-Fi TCP
port (or earshot-eval fake-clip), send a clock sync, ack every tap, and save
the clip->iPad byte stream (replay format) for `earshot-eval check-stream`.
Dev tooling only: the capture holds audio, so use test speech, not patients.

    python3 core/tools/capture_clip.py 192.168.4.1 7070 capture.replay --seconds 60
"""
import socket, struct, sys, time

host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
secs = float(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 60
s = socket.create_connection((host, port), timeout=5)
def frame(body): return struct.pack("<H", len(body)) + body
s.sendall(frame(struct.pack("<BHIQ", 4, 0, 0, int(time.time() * 1000))))   # clock
buf = b""; raw = b""; taps = 0; t0 = time.time(); s.settimeout(0.5)
while time.time() - t0 < secs:
    try: chunk = s.recv(4096)
    except socket.timeout: continue
    if not chunk: break
    raw += chunk; buf += chunk
    while len(buf) >= 2:
        n = struct.unpack_from("<H", buf)[0]
        if len(buf) < 2 + n: break
        p = buf[2:2 + n]; buf = buf[2 + n:]
        if p and p[0] == 2:   # tap -> ack its seq
            seq = struct.unpack_from("<H", p, 1)[0]; taps += 1
            s.sendall(frame(struct.pack("<BHIH", 5, 0, 0, seq)))
open(out, "wb").write(raw)
print(f"captured {len(raw)} bytes, {taps} tap packets -> {out}")
