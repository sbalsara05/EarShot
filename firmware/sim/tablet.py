#!/usr/bin/env python3
"""Mock tablet for the Earshot clip, plus the simulator UI.

It plays the tablet's side of the clip protocol (see lib/earshot_core/src/protocol.h):
a WebSocket server on /clip that accepts the clip's events and audio and can send it commands.
It keeps a ledger of exactly what arrived, so you can see that no audio is received unless the
clip is listening.

  python3 sim/tablet.py                 virtual clip + mock tablet, UI at http://localhost:8765
  python3 sim/tablet.py --no-sim --lan  mock tablet only, for a real clip on the same Wi-Fi

Needs the `websockets` package (pip install websockets). To play back or inspect Opus audio it
also needs PyAV (pip install av); without it, compressed audio is still counted but not decoded.
"""
import argparse
import asyncio
import base64
import datetime
import io
import json
import math
import pathlib
import struct
import sys
import wave

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Response

try:  # PyAV decodes Opus so compressed audio can be played back and checked; optional
    import av
except ImportError:
    av = None

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_SIM_BIN = HERE.parent / "build" / "sim_clip"
SAMPLE_RATE = 16000
KEEP_SECONDS = 120  # received audio kept in memory for the UI's playback button (test aid)


def wall() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


class MockTablet:
    def __init__(self, host="127.0.0.1", port=8765, sim_bin=None, sim_args=(), save_wav=False,
                 quiet=False, event_log=None):
        # Optional evidence log: one JSON object per line. Every message exchanged with the
        # clip, plus the tablet's ledger once a second whenever it changed.
        self._event_log = open(event_log, "a", buffering=1) if event_log else None
        self._logged_ledger = None
        self.host = host
        self.port = port
        self.sim_bin = sim_bin
        self.sim_args = list(sim_args)
        self.save_wav = save_wav
        self.quiet = quiet

        self.codec = "pcm"        # from the clip's hello: how its audio frames are encoded
        self.bitrate = 256000
        self._decoder = None
        self._resampler = None
        self.clip = None          # the clip's WebSocket (one at a time)
        self.uis = set()
        self.sim = None           # simulated clip process
        self.sim_status = {}
        self.sim_led = "off"
        self.sim_beeps = 0        # beeps the simulated clip has made ("find")
        self.server = None
        self._tasks = []
        self._wav = None
        self._dirty = True
        self.reset()

    # ------------------------------------------------------------------ ledger

    def reset(self):
        self.device = None
        self.device_state = "unknown"
        self.listening = False     # the clip says consent is logged and it is capturing
        self.captures = 0          # "granted" consent events received (captures started)
        self.audio_bytes = 0
        self.audio_frames = 0
        self.lost_frames = 0
        self.last_seq = None
        self.violations = 0       # audio frames that arrived while the clip was not listening (must stay 0)
        self.markers = []
        self.events = []          # every text event received, in order
        self.level = 0.0
        self._last_pcm = b""
        self._received = bytearray()  # the most recent KEEP_SECONDS of audio that arrived
        self._dirty = True

    def received_wav(self) -> bytes:
        """Everything in the playback buffer as a WAV file: exactly what the tablet was sent."""
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(bytes(self._received))
        return buf.getvalue()

    def snapshot(self):
        if self._last_pcm:
            samples = memoryview(self._last_pcm).cast("h")
            rms = math.sqrt(sum(s * s for s in samples) / len(samples)) if len(samples) else 0.0
            self.level = min(1.0, rms / 8000.0)
        return {
            "kind": "tablet",
            "clip_connected": self.clip is not None,
            "device": self.device,
            "device_state": self.device_state,
            "listening": self.listening,
            "captures": self.captures,
            "audio_bytes": self.audio_bytes,
            "audio_frames": self.audio_frames,
            "audio_seconds": round(self.audio_frames * 0.02, 2),
            "codec": self.codec,
            "bitrate": self.bitrate,
            # average bytes per second actually received, with and without the 8-byte frame headers
            "bytes_per_sec": round(self.audio_bytes / (self.audio_frames * 0.02)) if self.audio_frames else 0,
            "bytes_per_sec_with_headers": round((self.audio_bytes + 8 * self.audio_frames)
                                                / (self.audio_frames * 0.02)) if self.audio_frames else 0,
            "can_decode": self.codec == "pcm" or self._decoder is not None,
            "lost_frames": self.lost_frames,
            "violations": self.violations,
            "markers": self.markers[-20:],
            "level": round(self.level if self.listening else 0.0, 3),
            "playback_seconds": round(len(self._received) / 2 / SAMPLE_RATE, 1),
            "sim": {"running": self.sim is not None, "led": self.sim_led, **self.sim_status},
        }

    # ------------------------------------------------------------------ lifecycle

    async def start(self):
        self.server = await serve(self._handler, self.host, self.port,
                                  process_request=self._http, max_size=1 << 20)
        self._tasks.append(asyncio.create_task(self._push_snapshots()))
        if self.sim_bin:
            await self.start_sim()

    async def stop(self):
        await self.stop_sim()
        for t in self._tasks:
            t.cancel()
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        self._close_wav()

    async def start_sim(self):
        if self.sim is not None:
            return
        self.sim = await asyncio.create_subprocess_exec(
            str(self.sim_bin), "--host", "127.0.0.1", "--port", str(self.port), *self.sim_args,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        self._tasks.append(asyncio.create_task(self._read_sim(self.sim)))

    async def stop_sim(self):
        proc, self.sim = self.sim, None
        if proc is None:
            return
        try:
            proc.stdin.write(b"quit\n")
            await proc.stdin.drain()
            await asyncio.wait_for(proc.wait(), 2)
        except Exception:
            proc.kill()
        self.sim_status, self.sim_led = {}, "off"
        self._dirty = True

    async def sim_input(self, line: str):
        """Button input for the simulated clip: down, up, short, long, double."""
        if self.sim is None:
            return
        self.sim.stdin.write(line.encode() + b"\n")
        await self.sim.stdin.drain()

    async def sim_mic_source(self, source: str):
        """'laptop': the simulated clip hears audio passed to sim_audio(). 'tone': built-in tone."""
        await self.sim_input("mic ext" if source == "laptop" else "mic tone")

    async def sim_audio(self, pcm: bytes):
        """Sound reaching the simulated clip's microphone: 16 kHz mono int16 LE samples.
        This is the 'air' in front of the clip, not the stream. The clip's microphone only
        picks it up while it is listening with consent."""
        if self.sim is None or not pcm:
            return
        self.sim.stdin.write(b"a " + base64.b64encode(pcm) + b"\n")
        await self.sim.stdin.drain()

    async def send_command(self, cmd: str):
        """Tablet -> clip command: start, stop, marker."""
        if self.clip is None:
            return False
        await self.clip.send(json.dumps({"cmd": cmd}))
        self._log_event("tablet→clip", {"cmd": cmd})
        return True

    # ------------------------------------------------------------------ HTTP + WebSocket

    def _http(self, connection, request):
        if request.headers.get("Upgrade", "").lower() == "websocket":
            return None
        if request.path in ("/", "/index.html"):
            body = (HERE / "index.html").read_bytes()
            return Response(200, "OK", Headers([
                ("Content-Type", "text/html; charset=utf-8"),
                ("Content-Length", str(len(body))),
                ("Cache-Control", "no-store"),
            ]), body)
        if request.path.startswith("/received.wav"):
            body = self.received_wav()
            return Response(200, "OK", Headers([
                ("Content-Type", "audio/wav"),
                ("Content-Length", str(len(body))),
                ("Cache-Control", "no-store"),
            ]), body)
        return Response(404, "Not Found", Headers([("Content-Length", "0")]), b"")

    async def _handler(self, ws):
        path = ws.request.path
        if path == "/clip":
            await self._clip_session(ws)
        elif path == "/ui":
            await self._ui_session(ws)
        else:
            await ws.close(1008, "unknown path")

    async def _clip_session(self, ws):
        if self.clip is not None:
            await ws.close(1013, "another clip is connected")
            return
        self.clip = ws
        self.last_seq = None
        self._say(f"clip connected from {ws.remote_address[0]}")
        self._dirty = True
        try:
            async for msg in ws:
                if isinstance(msg, bytes):
                    self._on_audio(msg)
                else:
                    self._on_event(msg)
        except ConnectionClosed:
            pass
        finally:
            self.clip = None
            self.device_state = "unknown"
            self.listening = False
            self._close_wav()
            self._say("clip disconnected")
            self._dirty = True

    def _on_audio(self, msg: bytes):
        if len(msg) < 8:
            return
        seq, _t_ms = struct.unpack_from("<II", msg, 0)
        payload = msg[8:]
        pcm = self._decode(payload)
        if not self.listening:
            self.violations += 1
            self._say(f"!! audio frame seq={seq} arrived while the clip was NOT listening")
        if self.last_seq is not None and seq > self.last_seq + 1:
            self.lost_frames += seq - self.last_seq - 1
        self.last_seq = seq
        self.audio_frames += 1
        self.audio_bytes += len(payload)   # bytes on the wire, before decoding
        self._last_pcm = pcm[: len(pcm) & ~1]
        self._received += self._last_pcm
        excess = len(self._received) - KEEP_SECONDS * SAMPLE_RATE * 2
        if excess > 0:
            del self._received[:excess]
        if self.save_wav:
            self._wav_write(pcm)
        self._dirty = True

    def _decode(self, payload: bytes) -> bytes:
        """One received audio frame -> 16 kHz mono int16 samples (empty if it cannot be decoded)."""
        if self.codec == "pcm":
            return payload
        if self._decoder is None:
            return b""
        try:
            out = bytearray()
            for frame in self._decoder.decode(av.Packet(payload)):
                for r in self._resampler.resample(frame):
                    out += r.to_ndarray().tobytes()
            return bytes(out)
        except Exception as e:  # a corrupt packet must not take the tablet down
            self._say(f"could not decode an audio frame: {e}")
            return b""

    def _set_codec(self, audio: dict):
        self.codec = audio.get("codec", "pcm")
        self.bitrate = audio.get("bitrate", 256000)
        self._decoder = self._resampler = None
        if self.codec == "opus":
            if av is None:
                self._say("clip is sending Opus; install PyAV (pip install av) to decode it for playback")
                return
            self._decoder = av.CodecContext.create("libopus", "r")
            self._decoder.sample_rate = 48000
            self._decoder.layout = "mono"
            self._resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)

    def _on_event(self, text: str):
        try:
            ev = json.loads(text)
        except ValueError:
            self._say(f"unparseable message from clip: {text!r}")
            return
        kind = ev.get("type")
        if kind == "hello":
            self.device = ev.get("device")
            self.last_seq = None
            self._set_codec(ev.get("audio") or {})
        elif kind == "state":
            self.device_state = ev.get("state", "unknown")
            self.listening = bool(ev.get("listening"))
        elif kind == "consent":
            what = ev.get("event")
            if what == "granted":
                self.listening = True
                self.captures += 1
                self.last_seq = None  # each capture restarts the clip's frame counter
            elif what == "stopped":
                self.listening = False
        elif kind == "marker":
            self.markers.append({"id": ev.get("id"), "t_ms": ev.get("t_ms"),
                                 "audio_seq": ev.get("audio_seq"), "source": ev.get("source"),
                                 "wall": wall()})
        self._log_event("clip→tablet", ev)
        self._dirty = True

    def _log_event(self, direction, ev):
        entry = {"kind": "event", "dir": direction, "wall": wall(), "event": ev}
        self.events.append(entry)
        self._write_log({"wall": entry["wall"], "dir": direction, "message": ev})
        self._say(f"{direction}  {json.dumps(ev)}")
        self._broadcast(entry)

    async def _ui_session(self, ws):
        self.uis.add(ws)
        try:
            await ws.send(json.dumps(self.snapshot()))
            for entry in self.events[-50:]:
                await ws.send(json.dumps(entry))
            async for msg in ws:
                if isinstance(msg, bytes):  # laptop microphone audio for the simulated clip
                    await self.sim_audio(msg)
                    continue
                try:
                    m = json.loads(msg)
                except ValueError:
                    continue
                what = m.get("ui")
                if what == "mic":
                    await self.sim_mic_source(str(m.get("source")))
                elif what == "button":
                    await self.sim_input("down" if m.get("down") else "up")
                elif what == "cmd":
                    await self.send_command(str(m.get("cmd")))
                elif what == "reset":
                    keep = (self.device, self.device_state, self.listening)
                    self.reset()
                    self.device, self.device_state, self.listening = keep
                    self._broadcast({"kind": "cleared"})
                elif what == "sim":
                    if m.get("run"):
                        await self.start_sim()
                    else:
                        await self.stop_sim()
        except ConnectionClosed:
            pass
        finally:
            self.uis.discard(ws)

    async def _read_sim(self, proc):
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("sim") == "led":
                self.sim_led = m.get("color", "off")
                self._broadcast({"kind": "led", "color": self.sim_led})
            elif m.get("sim") == "beep":
                self.sim_beeps += 1 if m.get("on") else 0
                self._broadcast({"kind": "beep", "on": bool(m.get("on"))})
            elif m.get("sim") == "status":
                m.pop("sim")
                self.sim_status = m
            elif m.get("sim") == "log":
                self._say(f"sim clip: {m.get('msg')}")
            self._dirty = True
        if self.sim is proc:
            self.sim = None
            self.sim_status, self.sim_led = {}, "off"
            self._dirty = True

    async def _push_snapshots(self):
        ticks = 0
        while True:
            await asyncio.sleep(0.1)
            ticks += 1
            if ticks % 10 == 0:
                self._log_ledger()
            if self._dirty and self.uis:
                self._dirty = False
                self._broadcast(self.snapshot())

    def _log_ledger(self):
        ledger = {"clip_connected": self.clip is not None, "device_state": self.device_state,
                  "listening": self.listening, "codec": self.codec,
                  "audio_bytes_received": self.audio_bytes,
                  "audio_frames_received": self.audio_frames, "lost_frames": self.lost_frames,
                  "audio_frames_without_consent": self.violations, "captures_started": self.captures,
                  "markers": len(self.markers)}
        if self.sim_status:
            ledger["sim_clip"] = {k: self.sim_status.get(k) for k in
                                  ("state", "captured", "sent", "dropped", "mic")}
            ledger["sim_clip"]["led"] = self.sim_led
        comparable = json.dumps({k: v for k, v in ledger.items() if k != "sim_clip"})
        if comparable != self._logged_ledger:
            self._logged_ledger = comparable
            self._write_log({"wall": wall(), "ledger": ledger})

    def _write_log(self, obj):
        if self._event_log:
            self._event_log.write(json.dumps(obj) + "\n")

    def _broadcast(self, obj):
        data = json.dumps(obj)
        for ws in list(self.uis):
            asyncio.ensure_future(self._safe_send(ws, data))

    async def _safe_send(self, ws, data):
        try:
            await ws.send(data)
        except ConnectionClosed:
            self.uis.discard(ws)

    # ------------------------------------------------------------------ helpers

    def _wav_write(self, pcm: bytes):
        if self._wav is None:
            out_dir = HERE / "out"
            out_dir.mkdir(exist_ok=True)
            name = out_dir / f"received-{datetime.datetime.now():%Y%m%d-%H%M%S}.wav"
            self._wav = wave.open(str(name), "wb")
            self._wav.setnchannels(1)
            self._wav.setsampwidth(2)
            self._wav.setframerate(SAMPLE_RATE)
            self._say(f"saving received audio to {name}")
        self._wav.writeframes(pcm)

    def _close_wav(self):
        if self._wav is not None:
            self._wav.close()
            self._wav = None

    def _say(self, text):
        if not self.quiet:
            print(f"[{wall()}] {text}", flush=True)


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--lan", action="store_true",
                    help="listen on all interfaces so a real clip on the Wi-Fi can connect")
    ap.add_argument("--no-sim", action="store_true", help="do not start the simulated clip")
    ap.add_argument("--sim-bin", default=str(DEFAULT_SIM_BIN))
    ap.add_argument("--wav", help="16 kHz mono 16-bit WAV for the simulated mic (default: a tone)")
    ap.add_argument("--voice", action="store_true",
                    help="simulated mic plays the voice recording built into the firmware")
    ap.add_argument("--save-wav", action="store_true",
                    help="write received audio to sim/out/ (test tool only; the product never does this)")
    ap.add_argument("--event-log", metavar="FILE",
                    help="append every clip message and the tablet's ledger to FILE (JSON lines)")
    args = ap.parse_args()

    sim_bin = None
    if not args.no_sim:
        sim_bin = pathlib.Path(args.sim_bin)
        if not sim_bin.exists():
            sys.exit(f"{sim_bin} not found. Run `make sim` first (or pass --no-sim).")
    sim_args = ["--wav", args.wav] if args.wav else ["--voice"] if args.voice else []

    tablet = MockTablet("0.0.0.0" if args.lan else "127.0.0.1", args.port, sim_bin, sim_args,
                        save_wav=args.save_wav, event_log=args.event_log)
    await tablet.start()
    print(f"Simulator UI:   http://localhost:{args.port}")
    print(f"Clip endpoint:  ws://{'<this-laptop-ip>' if args.lan else 'localhost'}:{args.port}/clip")
    print("Ctrl+C to stop.\n")
    try:
        await asyncio.Future()
    finally:
        await tablet.stop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
