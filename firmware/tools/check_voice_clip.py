#!/usr/bin/env python3
"""Checks that the voice recording built into the firmware comes out the far end as the words
that went in.

Runs the simulated clip with the recording as its microphone (the same decoder and the same
Opus encoder as the device), receives the audio on the mock tablet, decodes it, transcribes it
with Whisper and compares the transcript with the script the recording was made from.

    make sim && build/codec-test-venv/bin/python tools/check_voice_clip.py

This is the laptop version of what the iPad should show when the Feather is streaming.
"""
import asyncio
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sim"))
from tablet import DEFAULT_SIM_BIN, MockTablet  # noqa: E402

PORT = 8797


def script_text():
    src = (ROOT / "lib/earshot_voice/src/voice_clip_data.c").read_text()
    return re.search(r'kVoiceClipText\[\] = "(.*?)";', src).group(1)


def clip_seconds():
    src = (ROOT / "lib/earshot_voice/src/voice_clip_data.c").read_text()
    return int(re.search(r"kVoiceClipBytes = (\d+);", src).group(1)) * 2 / 16000


def word_error_rate(ref, hyp):
    """Word-level edit distance divided by the number of reference words."""
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[-1] / max(1, len(ref))


async def capture(seconds):
    t = MockTablet(port=PORT, sim_bin=DEFAULT_SIM_BIN, sim_args=["--voice"], quiet=True)
    await t.start()
    try:
        for _ in range(500):
            if t.device:
                break
            await asyncio.sleep(0.02)
        # One pass through the recording, stopping in the silence at its end: a second, cut-off
        # reading would only confuse the transcriber.
        await t.send_command("start")
        await asyncio.sleep(seconds - 0.6)
        await t.send_command("stop")
        await asyncio.sleep(0.5)
        return t.received_wav(), t.audio_frames, t.audio_bytes, t.codec
    finally:
        await t.stop()


def main():
    if not DEFAULT_SIM_BIN.exists():
        sys.exit("build/sim_clip not found. Run `make sim` first.")
    from faster_whisper import WhisperModel
    from whisper_normalizer.english import EnglishTextNormalizer

    want = script_text()
    seconds = clip_seconds()
    wav, frames, nbytes, codec = asyncio.run(capture(seconds))
    out = pathlib.Path(tempfile.gettempdir()) / "earshot_voice_received.wav"
    out.write_bytes(wav)
    print(f"received {frames} frames, {nbytes:,} bytes of {codec} audio ({frames * 0.02:.1f} s)")

    model = WhisperModel("base.en", device="cpu", compute_type="int8")
    import numpy as np
    audio = np.frombuffer(wav[44:], dtype="<i2").astype(np.float32) / 32768.0  # 16 kHz mono
    segments, _ = model.transcribe(audio, language="en", temperature=0.0)
    got = " ".join(s.text.strip() for s in segments)
    norm = EnglishTextNormalizer()
    wer = word_error_rate(norm(want).split(), norm(got).split())
    print(f"script:      {want}")
    print(f"transcript:  {got}")
    print(f"word error rate: {wer * 100:.1f}%")
    ok = wer <= 0.10 and frames >= int(seconds * 50 * 0.9)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
