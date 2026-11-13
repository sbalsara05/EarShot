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

        print("press = ask for consent")
        await t.sim_input("short")
        check("clip reports asking", await wait_for(lambda: t.device_state == "asking"))
        check("ring is amber", await wait_for(lambda: t.sim_led == "amber"), t.sim_led)
        await asyncio.sleep(1.5)
        check("still nothing captured while asking", t.sim_status.get("captured", -1) == 0)
        check("tablet still at 0 audio bytes", t.audio_bytes == 0, f"{t.audio_bytes} bytes")

        print("press again = the patient said yes")
        await t.sim_input("short")
        check("clip reports listening", await wait_for(lambda: t.device_state == "listening" and t.listening))
        await asyncio.sleep(1.0)
        check("audio now arrives", t.audio_frames > 30, f"{t.audio_frames} frames, {t.audio_bytes} bytes")
        check("frames are 640 bytes of PCM", t.audio_bytes == t.audio_frames * 640)
        check("no frames lost", t.lost_frames == 0, f"{t.lost_frames} lost")
        check("ring is green", t.sim_led == "green", t.sim_led)
        check("consent events so far: asked, granted", consent_events(t) == ["asked", "granted"],
              str(consent_events(t)))

        print("double tap = marker")
        await t.sim_input("double")
        check("marker 1 received", await wait_for(lambda: len(t.markers) == 1))
        check("still listening after the marker", t.device_state == "listening")

        print("hold = stop")
        await t.sim_input("long")
        check("clip reports not listening", await wait_for(lambda: t.device_state == "not_listening", 4.0))
        await asyncio.sleep(0.3)
        n = t.audio_frames
        await asyncio.sleep(0.8)
        check("audio stops", t.audio_frames == n)
        check("ring is dark", t.sim_led == "off", t.sim_led)
        check("a stop is not logged as a refusal", t.refusals == 0 and consent_events(t)[-1] == "stopped")

        print("the next patient says no")
        await t.sim_input("short")
        check("clip reports asking", await wait_for(lambda: t.device_state == "asking"))
        await t.sim_input("long")
        check("hold while asking returns to not listening",
              await wait_for(lambda: t.device_state == "not_listening", 4.0))
        check("the refusal is logged", t.refusals == 1 and consent_events(t)[-1] == "declined")
        await asyncio.sleep(0.8)
        check("no audio was captured or sent for that patient", t.audio_frames == n)
        check("ring is dark", t.sim_led == "off", t.sim_led)

        print("tablet commands")
        await t.send_command("ask")
        check("tablet can start the ask", await wait_for(lambda: t.device_state == "asking"))
        await t.send_command("consent_grant")
        check("tablet can log the yes", await wait_for(lambda: t.device_state == "listening"))
        await asyncio.sleep(0.5)
        check("audio flows again", t.audio_frames > n)
        check("a new capture restarts the frame counter without a false loss", t.lost_frames == 0)
        await t.send_command("marker")
        check("tablet-requested marker received",
              await wait_for(lambda: len(t.markers) == 2 and t.markers[1]["source"] == "tablet"))
        await t.send_command("consent_decline")
        check("patient withdrawing stops the capture",
              await wait_for(lambda: t.device_state == "not_listening"))
        check("the withdrawal is logged as a refusal", t.refusals == 2)
        await asyncio.sleep(0.2)
        n = t.audio_frames
        await asyncio.sleep(0.8)
        check("audio stops after withdrawal", t.audio_frames == n, f"{t.audio_frames - n} extra frames")

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
        await t.send_command("consent_grant")
        check("consent logged", await wait_for(lambda: t.device_state == "listening"))
        await speak(1.0)
        await asyncio.sleep(0.3)
        got = bytes(t._received)
        peaks = sum(1 for (s,) in struct.iter_unpack("<h", got) if abs(s) == 12345)
        total = len(got) // 2
        check("the tablet receives the microphone signal intact", total > 8000 and peaks > 0.7 * total,
              f"{peaks} of {total} samples match")
        wav = t.received_wav()
        check("playback WAV is well formed", wav[:4] == b"RIFF" and len(wav) == 44 + len(got))
        await t.send_command("stop")
        check("tablet can stop the capture", await wait_for(lambda: t.device_state == "not_listening"))

        print("ledger")
        check("no audio frame ever arrived while the clip was not listening", t.violations == 0,
              f"{t.violations}")
    finally:
        await t.stop()

    print(f"\n{'PASS' if failures == 0 else 'FAILED'}: {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
