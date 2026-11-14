#!/usr/bin/env python3
"""A Mac stand-in for the iPad app's Bluetooth side.

Finds the clip, connects, subscribes, and prints what arrives: events, audio packets per
second, lost frames. It does the same five steps the app has to do (BLUETOOTH.md), and it
reconnects by itself when the clip goes away and comes back, so it doubles as a reference.

    build/codec-test-venv/bin/python tools/ble_receiver.py --start --seconds 13 --transcribe

    --start        tell the clip to start a capture as soon as it is connected (otherwise press
                   the clip's button)
    --seconds N    stop the capture and quit after N seconds of audio
    --find         ask the clip to blink and beep ("Find clip"), wait for it to finish, and quit
    --app          stand in for the app's button handling: answer each double click (toggle
                   the recording) with start, or stop if one is running; print each mark; and
                   on a hold (toggle the call) end the open call and save it to its own files
                   in build/calls/, or open a new call if none is open
    --wav FILE     where to save the decoded audio (default: build/ble_received.wav)
    --transcribe   transcribe the saved audio with Whisper at the end

Run it from Terminal, not from an editor's built-in terminal: macOS asks once for permission
for the terminal app to use Bluetooth. Needs: pip install bleak av (and faster-whisper for
--transcribe); the project's test environment has them.
"""
import argparse
import asyncio
import json
import pathlib
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner

try:
    import av
except ImportError:  # still useful without it: packets are counted, just not decoded
    av = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVICE = "e5a70001-7c1b-4f0e-9d52-3a6b8c4d2e10"
AUDIO = "e5a70002-7c1b-4f0e-9d52-3a6b8c4d2e10"     # notify: 8-byte header + one audio frame
EVENTS = "e5a70003-7c1b-4f0e-9d52-3a6b8c4d2e10"    # notify: one JSON message
COMMANDS = "e5a70004-7c1b-4f0e-9d52-3a6b8c4d2e10"  # write: one JSON command
RATE = 16000


def stamp():
    t = time.time()
    return time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d}"


class Receiver:
    def __init__(self):
        self.codec = None
        self.decoder = self.resampler = None
        self.pcm = bytearray()
        self.frames = self.bytes = self.lost = 0
        self.next_seq = None
        self.listening = False
        self.hello = asyncio.Event()
        self.window_frames = self.window_bytes = 0
        self.answer = None  # set by --app: called with "start" or "stop" to answer a toggle
        # --app: the call in progress, from its first recording to the hold that ends it
        self.call_open = False
        self.call_recordings = 0
        self.call_marks = []
        self.calls_saved = 0

    # ---- events channel
    def on_event(self, _sender, data: bytearray):
        text = bytes(data).decode("utf-8", "replace")
        print(f"{stamp()}  event  {text}")
        try:
            ev = json.loads(text)
        except ValueError:
            return
        if ev.get("type") == "hello":
            audio = ev.get("audio", {})
            self.codec = audio.get("codec")
            if self.codec == "opus" and av is not None:
                self.decoder = av.CodecContext.create("libopus", "r")
                self.decoder.sample_rate = 48000
                self.decoder.layout = "mono"
                self.resampler = av.AudioResampler(format="s16", layout="mono", rate=RATE)
            self.hello.set()
        elif ev.get("type") == "consent" and ev.get("event") == "granted":
            self.next_seq = 0  # the frame counter restarts with every capture
            self.call_recordings += 1
        elif ev.get("type") == "state":
            self.listening = bool(ev.get("listening"))
        elif ev.get("type") == "toggle" and ev.get("target") == "call":
            # A hold: toggle the call. End the one that is open, or open a new one.
            if not self.answer:
                print(f"{stamp()}  CALL TOGGLE: the medic held the button (run with --app to act on it)")
            elif self.call_open:
                self.save_call()
            else:
                self.call_open = True
                print(f"{stamp()}  NEW CALL opened: double-click the clip to start recording")
        elif ev.get("type") == "toggle" and self.answer:
            # A double click: toggle the recording. Decide as the app would.
            self.call_open = True  # a recording with no call open starts a new call
            self.answer("stop" if self.listening else "start")
        elif ev.get("type") == "marker":
            print(f"{stamp()}  MARK {ev.get('id')} at audio packet {ev.get('audio_seq')} "
                  f"({ev.get('audio_seq', 0) * 0.02:.1f} s into the recording)")
            self.call_marks.append({"recording": self.call_recordings,
                                    "seconds_into_recording": round(ev.get("audio_seq", 0) * 0.02, 2),
                                    "source": ev.get("source")})

    # ---- audio channel
    def on_audio(self, _sender, data: bytearray):
        if len(data) < 8:
            return
        seq, _t_ms = struct.unpack_from("<II", data, 0)
        payload = bytes(data[8:])
        if self.next_seq is not None and seq > self.next_seq:
            self.lost += seq - self.next_seq
        self.next_seq = seq + 1
        self.frames += 1
        self.bytes += len(data)
        self.window_frames += 1
        self.window_bytes += len(data)
        if self.codec == "pcm":
            self.pcm += payload
        elif self.decoder is not None:
            try:
                for frame in self.decoder.decode(av.Packet(payload)):
                    for r in self.resampler.resample(frame):
                        self.pcm += r.to_ndarray().tobytes()
            except Exception as e:  # one bad packet should not end the run
                print(f"{stamp()}  could not decode frame {seq}: {e}")

    def save_call(self):
        """--app: the hold that ends a call. Save it to its own files, then start afresh, so the
        next double click begins a new call."""
        self.call_open = False
        if not self.call_recordings:
            print(f"{stamp()}  END CALL: the call had no recordings, nothing to save")
            return
        self.calls_saved += 1
        name = time.strftime("call-%Y%m%d-%H%M%S")
        folder = ROOT / "build" / "calls"
        self.save(folder / f"{name}.wav")
        summary = {"ended": time.strftime("%Y-%m-%d %H:%M:%S"), "recordings": self.call_recordings,
                   "audio_seconds": round(len(self.pcm) / 2 / RATE, 1), "marks": self.call_marks}
        (folder / f"{name}.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"{stamp()}  END CALL: saved {folder / name}.wav and .json "
              f"({summary['recordings']} recording(s), {summary['audio_seconds']} s, {len(self.call_marks)} mark(s))")
        print(f"{stamp()}  (the app would also generate the reports here)")
        print(f"{stamp()}  ready for a new call: hold again to open one, or double-click to start recording")
        self.pcm = bytearray()
        self.call_recordings = 0
        self.call_marks = []

    def save(self, path: pathlib.Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(bytes(self.pcm))


async def run(args):
    rx = Receiver()
    wav_path = pathlib.Path(args.wav)
    done = asyncio.Event()

    while not done.is_set():
        # Step 1: scan for the clip's service ID.
        print(f"{stamp()}  scanning for an Earshot clip...")
        device = None
        while device is None:
            device = await BleakScanner.find_device_by_filter(
                lambda d, adv: SERVICE in [u.lower() for u in adv.service_uuids], timeout=10.0)
        print(f"{stamp()}  found {device.name or '(no name)'}")

        gone = asyncio.Event()
        try:
            # Step 2: connect.
            async with BleakClient(device, disconnected_callback=lambda _c: gone.set()) as client:
                print(f"{stamp()}  connected; packets can carry {client.mtu_size - 3} bytes")
                rx.hello.clear()
                # Steps 3 and 4: the channels are looked up on connect; subscribe to both.
                # Audio first, so no frame is missed once the clip sees the events subscription.
                await client.start_notify(AUDIO, rx.on_audio)
                await client.start_notify(EVENTS, rx.on_event)
                await asyncio.wait_for(rx.hello.wait(), 5.0)
                if args.app:
                    def answer(cmd, client=client):
                        print(f"{stamp()}  double click: answering {cmd}")
                        asyncio.ensure_future(
                            client.write_gatt_char(COMMANDS, json.dumps({"cmd": cmd}).encode(), response=True))
                    rx.answer = answer
                    print(f"{stamp()}  standing in for the app: double-click the clip to start or stop, "
                          "single-click while it is red for a mark. Ctrl-C to quit.")
                if args.find:
                    await client.write_gatt_char(COMMANDS, b'{"cmd":"find"}', response=True)
                    print(f"{stamp()}  sent find: the clip should blink (and beep, if it has a speaker) for about 3 seconds")
                    await asyncio.sleep(4.0)
                    done.set()
                    break
                if args.start and not rx.listening:
                    await client.write_gatt_char(COMMANDS, b'{"cmd":"start"}', response=True)

                # Step 5: receive. Report once a second while audio is flowing.
                while not gone.is_set():
                    await asyncio.sleep(1.0)
                    if rx.window_frames:
                        print(f"{stamp()}  audio  {rx.window_frames} packets, {rx.window_bytes:,} bytes "
                              f"in the last second; {rx.frames} frames so far, {rx.lost} lost")
                    rx.window_frames = rx.window_bytes = 0
                    if args.seconds and rx.frames >= args.seconds * 50:
                        await client.write_gatt_char(COMMANDS, b'{"cmd":"stop"}', response=True)
                        await asyncio.sleep(0.5)
                        done.set()
                        break
        except Exception as e:  # any link failure: report it and look for the clip again
            print(f"{stamp()}  link problem: {e!r}")
        if not done.is_set():
            print(f"{stamp()}  clip disconnected; looking for it again")

    seconds = len(rx.pcm) / 2 / RATE
    print(f"\nreceived {rx.frames} audio frames ({rx.frames * 0.02:.1f} s), {rx.bytes:,} bytes, {rx.lost} lost")
    if rx.pcm:
        rx.save(wav_path)
        print(f"decoded audio saved to {wav_path} ({seconds:.1f} s)")
    elif rx.frames:
        print("audio was not decoded (install PyAV: pip install av)")
    if args.transcribe and rx.pcm:
        import numpy as np
        from faster_whisper import WhisperModel
        audio = np.frombuffer(bytes(rx.pcm), dtype="<i2").astype(np.float32) / 32768.0
        segments, _ = WhisperModel("base.en", device="cpu", compute_type="int8").transcribe(
            audio, language="en", temperature=0.0)
        print("transcript: " + " ".join(s.text.strip() for s in segments))


def main():
    ap = argparse.ArgumentParser(description="Receive the Earshot clip's Bluetooth stream on a Mac.")
    ap.add_argument("--start", action="store_true", help="start a capture as soon as connected")
    ap.add_argument("--seconds", type=float, default=0, help="quit after this much audio")
    ap.add_argument("--find", action="store_true", help="make the clip blink and beep, then quit")
    ap.add_argument("--app", action="store_true",
                    help="answer double clicks like the app (start, or stop if recording) and print marks")
    ap.add_argument("--wav", default=str(ROOT / "build" / "ble_received.wav"))
    ap.add_argument("--transcribe", action="store_true")
    args = ap.parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    sys.exit(main())
