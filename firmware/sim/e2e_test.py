#!/usr/bin/env python3
"""End-to-end check: the simulated clip (real firmware core) against the mock tablet over a
real WebSocket. Run with `make e2e`. Takes about 20 seconds because it runs in real time."""
import asyncio
import pathlib
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tablet import DEFAULT_SIM_BIN, MockTablet  # noqa: E402

PORT = 8799
failures = 0


def check(label, ok, detail=""):
    global failures
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}" + (f"   ({detail})" if detail else ""))
    if not ok:
        failures += 1


async def wait_for(pred, timeout=3.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while loop.time() < end:
        if pred():
            return True
        await asyncio.sleep(0.02)
    return pred()


def consent_events(t):
    return [e["event"]["event"] for e in t.events
            if e["dir"].startswith("clip") and e["event"].get("type") == "consent"]


async def main():
    if not DEFAULT_SIM_BIN.exists():
        sys.exit("build/sim_clip not found. Run `make sim` first.")
    t = MockTablet(port=PORT, sim_bin=DEFAULT_SIM_BIN, quiet=True)
    await t.start()
    try:
        print("power-on: not listening")
        # Generous timeout: the first launch of a freshly built binary can be slow on macOS.
        check("clip connects and says hello", await wait_for(lambda: t.device == "earshot-clip-sim", 10.0))
        check("clip reports not listening", await wait_for(lambda: t.device_state == "not_listening"))
        await asyncio.sleep(1.5)
        check("microphone is off: nothing captured", t.sim_status.get("captured", -1) == 0,
              f"{t.sim_status.get('captured')} frames captured")
        check("tablet received 0 audio bytes", t.audio_bytes == 0, f"{t.audio_bytes} bytes")
        check("ring is dark", t.sim_led == "off", t.sim_led)

        print("gestures that must not start a capture")
        await t.sim_input("double")
        await asyncio.sleep(0.9)
        await t.sim_input("long")
        await asyncio.sleep(2.2)
        check("double tap and hold do nothing while not listening",
              t.device_state == "not_listening" and t.audio_bytes == 0 and not consent_events(t))

        print("press = start (consent logged)")
        await t.sim_input("short")
        check("clip reports listening", await wait_for(lambda: t.device_state == "listening" and t.listening))
        await asyncio.sleep(1.0)
        check("audio now arrives", t.audio_frames > 30, f"{t.audio_frames} frames, {t.audio_bytes} bytes")
        check("clip says it is sending Opus at 32 kbit/s", t.codec == "opus" and t.bitrate == 32000,
              f"{t.codec} {t.bitrate}")
        check("every frame is one 80-byte Opus packet", t.audio_bytes == t.audio_frames * 80,
              f"{t.audio_bytes} bytes in {t.audio_frames} frames")
        rate = (t.audio_bytes + 8 * t.audio_frames) / (t.audio_frames * 0.02)
        check("data rate with headers is under 8,000 bytes per second", rate <= 8000, f"{rate:.0f} bytes/s")
        check("no frames lost", t.lost_frames == 0, f"{t.lost_frames} lost")
        check("ring is green", t.sim_led == "green", t.sim_led)
        check("the press was logged as consent", consent_events(t) == ["granted"], str(consent_events(t)))

        print("double tap = marker")
        await t.sim_input("double")
        check("marker 1 received", await wait_for(lambda: len(t.markers) == 1))
        check("still listening after the marker", t.device_state == "listening")

        print("a stray press while listening")
        await t.sim_input("short")
        await asyncio.sleep(0.8)
        check("is ignored", t.device_state == "listening" and consent_events(t) == ["granted"])

        print("hold = stop")
        await t.sim_input("long")
        check("clip reports not listening", await wait_for(lambda: t.device_state == "not_listening", 4.0))
        await asyncio.sleep(0.3)
        n = t.audio_frames
        await asyncio.sleep(0.8)
        check("audio stops", t.audio_frames == n)
        check("ring is dark", t.sim_led == "off", t.sim_led)
        check("the stop was logged", consent_events(t) == ["granted", "stopped"], str(consent_events(t)))

        print("tablet commands")
        await t.send_command("start")
        check("tablet can start a capture", await wait_for(lambda: t.device_state == "listening"))
        await asyncio.sleep(0.5)
        check("audio flows again", t.audio_frames > n)
        check("a new capture restarts the frame counter without a false loss", t.lost_frames == 0)
        await t.send_command("marker")
        check("tablet-requested marker received",
              await wait_for(lambda: len(t.markers) == 2 and t.markers[1]["source"] == "tablet"))
        await t.send_command("stop")
        check("tablet can stop the capture", await wait_for(lambda: t.device_state == "not_listening"))
        await asyncio.sleep(0.2)
        n = t.audio_frames
        await asyncio.sleep(0.8)
        check("audio stops after the tablet's stop", t.audio_frames == n, f"{t.audio_frames - n} extra frames")

        print("external microphone (what the browser's laptop-mic option uses)")
        # A recognisable signal: a square wave at 250 Hz, amplitude 12345.
        frame = b"".join(struct.pack("<h", 12345 if (i // 32) % 2 == 0 else -12345) for i in range(320))
        await t.sim_mic_source("laptop")
        check("clip reports external mic", await wait_for(lambda: t.sim_status.get("mic") == "ext"))

        async def speak(seconds):
            for _ in range(int(seconds * 50)):
                await t.sim_audio(frame)
                await asyncio.sleep(0.02)

        t._received.clear()
        await speak(1.0)                                    # "talking" while the clip is not listening
        check("speech while not listening never reaches the tablet",
              t.audio_frames == n and len(t._received) == 0)
        await t.send_command("start")
        check("capture started", await wait_for(lambda: t.device_state == "listening"))
        await speak(1.0)
        await asyncio.sleep(0.3)
        got = [x for (x,) in struct.iter_unpack("<h", bytes(t._received))]
        if t._decoder is None:
            print("  skip  decoding checks (PyAV not installed in this Python)")
        else:
            # Opus is lossy, so compare the character of the signal rather than exact samples:
            # the 250 Hz square wave should come back at 250 Hz and at a similar loudness.
            # Measure inside the stretch where the "speech" was playing (the end is silence).
            tail = got[len(got) // 5: len(got) // 2]
            crossings = sum(1 for a, b in zip(tail, tail[1:]) if (a < 0) != (b < 0))
            hz = crossings / 2 / (len(tail) / 16000)
            rms = (sum(x * x for x in tail) / len(tail)) ** 0.5
            check("decoded audio has the microphone's pitch", 225 <= hz <= 275, f"{hz:.0f} Hz, expected 250")
            check("decoded audio has the microphone's loudness", 8000 <= rms <= 16000, f"rms {rms:.0f}")
        wav = t.received_wav()
        check("playback WAV is well formed", wav[:4] == b"RIFF" and len(wav) == 44 + 2 * len(got))
        await t.send_command("stop")
        check("capture stopped", await wait_for(lambda: t.device_state == "not_listening"))

        print("ledger")
        check("no audio frame ever arrived while the clip was not listening", t.violations == 0,
              f"{t.violations}")
        check("consent was logged once per capture", t.captures == 3, f"{t.captures}")
    finally:
        await t.stop()

    await raw_audio_pass()
    print(f"\n{'PASS' if failures == 0 else 'FAILED'}: {failures} failed")
    return 1 if failures else 0


async def raw_audio_pass():
    """The fallback setting: uncompressed audio (sim_clip --pcm)."""
    t = MockTablet(port=PORT, sim_bin=DEFAULT_SIM_BIN, sim_args=["--pcm"], quiet=True)
    await t.start()
    try:
        print("raw audio setting (fallback)")
        check("clip says it is sending raw audio", await wait_for(lambda: t.device is not None, 10.0)
              and t.codec == "pcm", t.codec)
        frame = b"".join(struct.pack("<h", 12345 if (i // 32) % 2 == 0 else -12345) for i in range(320))
        await t.sim_mic_source("laptop")
        await wait_for(lambda: t.sim_status.get("mic") == "ext")
        await t.send_command("start")
        await wait_for(lambda: t.device_state == "listening")
        for _ in range(50):
            await t.sim_audio(frame)
            await asyncio.sleep(0.02)
        await asyncio.sleep(0.3)
        check("frames are 640 bytes of PCM", t.audio_frames > 30 and t.audio_bytes == t.audio_frames * 640)
        got = bytes(t._received)
        peaks = sum(1 for (x,) in struct.iter_unpack("<h", got) if abs(x) == 12345)
        total = len(got) // 2
        check("raw audio arrives sample for sample", total > 8000 and peaks > 0.7 * total,
              f"{peaks} of {total} samples match")
    finally:
        await t.stop()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
