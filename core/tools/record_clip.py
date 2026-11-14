#!/usr/bin/env python3
"""Record what the clip sends, as a .clipcap file the pipeline can replay.

Acts as the tablet's WebSocket gateway (ws://HOST:PORT/clip, the firmware's Wi-Fi link) and writes
every message as it arrives: one JSON object per line,
    {"t": <epoch ms on receipt>, "text": "<JSON event>"}     events
    {"t": <epoch ms on receipt>, "bin": "<base64>"}          audio frames (8-byte header + Opus or pcm)

Then run the capture through the same live pipeline the iPad uses:
    swift run -c release earshot-eval out.clipcap --asr-model models/ggml-base.en.bin

Two ways to use it:
  --sim firmware/build/sim_clip   start the firmware simulator (the real firmware core) with its
                                  built-in voice, press start, double-tap a marker, hold to stop
  (no --sim)                      wait for a real clip on Wi-Fi; press its button yourself, Ctrl-C to finish

Needs: pip install websockets
"""
import argparse
import asyncio
import base64
import json
import sys
import time

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="capture file to write (.clipcap)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--sim", help="path to firmware/build/sim_clip to drive automatically")
    ap.add_argument("--pcm", action="store_true", help="ask the simulator for raw pcm instead of Opus")
    ap.add_argument("--seconds", type=float, default=15.0, help="how long the simulated capture runs")
    args = ap.parse_args()

    out = open(args.out, "w")
    hello = asyncio.Event()
    counts = {"text": 0, "bin": 0}

    async def handler(ws):
        if ws.request.path != "/clip":
            await ws.close()
            return
        try:
            async for msg in ws:
                record(msg)
        except ConnectionClosed:
            pass                                 # the clip went away; what arrived is kept

    def record(msg):
        t = int(time.time() * 1000)
        if isinstance(msg, bytes):
            out.write(json.dumps({"t": t, "bin": base64.b64encode(msg).decode()}) + "\n")
            counts["bin"] += 1
        else:
            out.write(json.dumps({"t": t, "text": msg}) + "\n")
            counts["text"] += 1
            if json.loads(msg).get("type") == "hello":
                hello.set()
        out.flush()

    async with serve(handler, args.host, args.port, max_size=None):
        print(f"listening on ws://{args.host}:{args.port}/clip", file=sys.stderr)
        if not args.sim:
            try:
                await asyncio.Future()
            except asyncio.CancelledError:
                pass
            return
        cmd = [args.sim, "--host", args.host, "--port", str(args.port), "--voice"] + (["--pcm"] if args.pcm else [])
        proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL)

        async def say(line):
            proc.stdin.write(line.encode() + b"\n")
            await proc.stdin.drain()

        await asyncio.wait_for(hello.wait(), 10)
        await asyncio.sleep(0.5)
        await say("short")                       # press: consent, capture starts
        await asyncio.sleep(args.seconds / 2)
        await say("double")                      # marker
        await asyncio.sleep(args.seconds / 2)
        await say("long")                        # hold 1.8 s: stop
        await asyncio.sleep(3.0)
        await say("quit")
        await proc.wait()
    out.close()
    print(f"wrote {args.out}: {counts['text']} events, {counts['bin']} audio frames", file=sys.stderr)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
