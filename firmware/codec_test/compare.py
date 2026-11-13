#!/usr/bin/env python3
"""Does compressing the clip's audio hurt transcripts?

The clip captures 16 kHz, 16-bit mono audio: 32,000 bytes per second. A Bluetooth link to iOS has
room for roughly 8,000. This test takes the same speech, passes it through several ways of
fitting that budget, transcribes every version with Whisper, and counts the word errors.

  speech (generated voices, or your own recordings)
    -> optional ambulance noise
    -> raw | Opus at several bitrates | ADPCM | 8 kHz sampling | Opus with lost chunks
    -> Whisper -> word error rate against what was actually said

Run (from firmware/):
  build/codec-test-venv/bin/python codec_test/compare.py
  build/codec-test-venv/bin/python codec_test/compare.py --recordings my_calls/

--recordings takes a folder of audio files (wav, m4a, mp3...) each with a .txt file of the same
name holding the words that were said. Results go to codec_test/results/.
"""
import argparse
import io
import json
import pathlib
import re
import subprocess
import sys
import time

import av
import numpy as np
from scipy import signal
from scipy.io import wavfile

HERE = pathlib.Path(__file__).resolve().parent
CACHE = HERE.parent / "build" / "codec_test"
SR = 16000
RAW_BYTES_PER_SEC = SR * 2
BUDGET = 8000

# An EMS call, written the way it would be spoken. Numbers are spelled out so the voices read
# them unambiguously; both sides are normalised to digits before scoring.
SCRIPT = [
    "Hi, my name is Jordan, I'm a paramedic. Can you tell me what happened today?",
    "I was carrying groceries up the stairs and I got this tight pressure in my chest.",
    "The pain started about twenty minutes ago and it goes down my left arm.",
    "On a scale of one to ten, how bad is the pain right now?",
    "It's about a seven, and I feel short of breath and a little dizzy.",
    "Do you have any allergies to medications?",
    "I'm allergic to penicillin and I take lisinopril for high blood pressure.",
    "Blood pressure is one hundred fifty eight over ninety four, heart rate one hundred twelve.",
    "Oxygen saturation is ninety three percent on room air, respiratory rate twenty two.",
    "Giving three hundred twenty four milligrams of aspirin, chewed, right now.",
    "Dispatch said this was a fall, but the patient denies falling or hitting his head.",
    "Have you had any heart problems before, or a history of diabetes?",
    "I had a stent placed two years ago and my father died of a heart attack.",
    "Starting oxygen at four liters per minute by nasal cannula.",
    "The twelve lead shows elevation in the inferior leads, transmitting to the hospital.",
    "Blood glucose is one hundred eighteen, pupils are equal and reactive.",
    "Sir, we are going to take you to the hospital now, is that okay with you?",
    "Yes, please, and can someone call my wife and tell her where I am going?",
    "Starting an intravenous line in the left forearm with normal saline running.",
    "Administering zero point four milligrams of nitroglycerin under the tongue.",
    "The pain is down to a four out of ten after the nitroglycerin.",
    "The patient is alert and oriented, skin is pale and sweaty, no leg swelling.",
    "Estimated arrival at the emergency department is in eight minutes.",
    "Handing off a sixty one year old male with chest pain and a possible heart attack.",
]
# Natural-sounding system voices with different accents (US, UK, Australian, Irish, South African).
PREFERRED_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Tessa", "Alex"]


# ------------------------------------------------------------------ audio in

def available_voices(limit):
    """Exact `say` voice names for the preferred voices installed on this Mac. The system lists
    some as "Daniel" and some as "Daniel (English (UK))", so match on the leading name."""
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    names = []
    for line in out.splitlines():
        m = re.match(r"^(.*?)\s+[a-z]{2}_[A-Z0-9]+\s+#", line)
        if m:
            names.append(m.group(1).strip())
    chosen = []
    for want in PREFERRED_VOICES:
        match = next((n for n in names if n == want or n.startswith(want + " (")), None)
        if match and match not in chosen:
            chosen.append(match)
    return chosen[:limit]


def synthesize(voices, lines):
    """macOS voices reading the script. Cached by voice name and text, so reruns use identical audio."""
    import hashlib
    tts = CACHE / "tts"
    tts.mkdir(parents=True, exist_ok=True)
    items = []
    for voice in voices:
        short = voice.split(" ")[0]
        for li, text in enumerate(lines):
            key = hashlib.sha256(f"{voice}|185|{text}".encode()).hexdigest()[:12]
            path = tts / f"{short}_{li:02d}_{key}.wav"
            if not path.exists():
                subprocess.run(["say", "-v", voice, "-r", "185", "-o", str(path),
                                f"--data-format=LEI16@{SR}", text], check=True)
            rate, pcm = wavfile.read(path)
            assert rate == SR
            items.append({"id": f"{short}-{li:02d}", "text": text, "pcm": pcm.astype(np.int16)})
    return items


def load_any(path):
    """Any audio file -> 16 kHz mono int16."""
    resampler = av.AudioResampler(format="s16", layout="mono", rate=SR)
    chunks = []
    with av.open(str(path)) as container:
        for frame in container.decode(audio=0):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1))
    return np.concatenate(chunks).astype(np.int16)


def load_recordings(folder):
    items = []
    for txt in sorted(pathlib.Path(folder).glob("*.txt")):
        audio = [p for p in txt.parent.glob(txt.stem + ".*") if p.suffix.lower() != ".txt"]
        if not audio:
            continue
        items.append({"id": txt.stem, "text": txt.read_text().strip(), "pcm": load_any(audio[0])})
    return items


def group(items, max_seconds=26.0, gap_seconds=0.4):
    """Join short utterances into clips of up to ~26 s. Whisper works on 30 s windows, so this
    is several times faster than one utterance at a time, and closer to a continuous stream."""
    gap = np.zeros(int(gap_seconds * SR), dtype=np.int16)
    clips, cur, cur_len = [], [], 0
    def flush():
        if cur:
            clips.append({"id": f"{cur[0]['id']}..{cur[-1]['id']}",
                          "text": " ".join(i["text"] for i in cur),
                          "pcm": np.concatenate([x for i in cur for x in (i["pcm"], gap)])})
    for item in items:
        n = len(item["pcm"]) + len(gap)
        same_speaker = not cur or cur[-1]["id"].split("-")[0] == item["id"].split("-")[0]
        if cur and (cur_len + n > max_seconds * SR or not same_speaker):
            flush()
            cur, cur_len = [], 0
        cur.append(item)
        cur_len += n
    flush()
    return clips


# ------------------------------------------------------------------ noise

def ambulance_noise(n, rng):
    """Engine and road rumble, cabin hiss and a wailing siren."""
    white = rng.standard_normal(n)
    b, a = signal.butter(4, 400 / (SR / 2), "low")
    rumble = signal.lfilter(b, a, white)
    rumble /= np.std(rumble)
    t = np.arange(n) / SR
    wail = 1075 + 425 * signal.sawtooth(2 * np.pi * t / 4.0, 0.5)  # 650-1500 Hz, 4 s cycle
    phase = 2 * np.pi * np.cumsum(wail) / SR
    siren = np.sin(phase) + 0.4 * np.sin(2 * phase) + 0.2 * np.sin(3 * phase)
    siren /= np.std(siren)
    return rumble + 0.5 * siren + 0.2 * white


def add_noise(pcm, snr_db, rng):
    x = pcm.astype(np.float64)
    noise = ambulance_noise(len(x), rng)
    speech_rms = np.sqrt(np.mean(x ** 2)) + 1e-9
    noise *= speech_rms / (10 ** (snr_db / 20)) / np.sqrt(np.mean(noise ** 2))
    return np.clip(x + noise, -32768, 32767).astype(np.int16)


# ------------------------------------------------------------------ codecs
# Each takes int16 PCM at 16 kHz and returns (what the tablet would decode, bytes per second sent).

def _roundtrip(pcm, codec, container_format, rate, bit_rate=None, options=None):
    buf = io.BytesIO()
    out = av.open(buf, "w", format=container_format)
    stream = out.add_stream(codec, rate=rate, layout="mono")
    if bit_rate:
        stream.bit_rate = bit_rate
    if options:
        stream.options = options
    frame = av.AudioFrame.from_ndarray(pcm.reshape(1, -1), format="s16", layout="mono")
    frame.sample_rate = rate
    payload = 0
    for packet in stream.encode(frame):
        payload += packet.size
        out.mux(packet)
    for packet in stream.encode(None):
        payload += packet.size
        out.mux(packet)
    out.close()
    buf.seek(0)
    resampler = av.AudioResampler(format="s16", layout="mono", rate=rate)
    chunks = []
    with av.open(buf, "r") as inp:
        for decoded in inp.decode(audio=0):
            for r in resampler.resample(decoded):
                chunks.append(r.to_ndarray().reshape(-1))
        for r in resampler.resample(None):
            chunks.append(r.to_ndarray().reshape(-1))
    audio = np.concatenate(chunks).astype(np.int16)
    return audio, payload / (len(pcm) / rate)


def raw(pcm):
    return pcm, float(RAW_BYTES_PER_SEC)


def opus(kbps):
    # Speech mode, 20 ms packets, constant bitrate (a predictable budget), and low encoder
    # effort, because the clip's ESP32 has to do this in real time.
    def run(pcm):
        return _roundtrip(pcm, "libopus", "ogg", SR, bit_rate=kbps * 1000,
                          options={"application": "voip", "frame_duration": "20", "vbr": "off",
                                   "compression_level": "1"})
    return run


def adpcm(pcm):
    return _roundtrip(pcm, "adpcm_ima_wav", "wav", SR)


def narrowband(pcm):
    down = signal.resample_poly(pcm.astype(np.float64), 1, 2)
    up = signal.resample_poly(down, 2, 1)[: len(pcm)]
    return np.clip(up, -32768, 32767).astype(np.int16), 8000 * 2.0


def narrowband_adpcm(pcm):
    down = np.clip(signal.resample_poly(pcm.astype(np.float64), 1, 2), -32768, 32767).astype(np.int16)
    decoded, rate = _roundtrip(down, "adpcm_ima_wav", "wav", 8000)
    up = signal.resample_poly(decoded.astype(np.float64), 2, 1)[: len(pcm)]
    return np.clip(up, -32768, 32767).astype(np.int16), rate


def opus_with_loss(kbps, loss, seed):
    def run(pcm):
        audio, rate = opus(kbps)(pcm)
        audio = audio.copy()
        rng = np.random.default_rng(seed + len(pcm))
        chunk = SR // 50  # 20 ms
        for start in range(0, len(audio) - chunk, chunk):
            if rng.random() < loss:
                audio[start:start + chunk] = 0  # worst case: the gap is left as silence
        return audio, rate
    return run


CONDITIONS = [
    ("Raw audio (today)", raw),
    ("Opus 48 kbit/s", opus(48)),
    ("Opus 32 kbit/s", opus(32)),
    ("Opus 24 kbit/s", opus(24)),
    ("Opus 16 kbit/s", opus(16)),
    ("Opus 12 kbit/s", opus(12)),
    ("Opus 8 kbit/s", opus(8)),
    ("ADPCM 4:1", adpcm),
    ("8 kHz sampling, uncompressed", narrowband),
    ("8 kHz sampling + ADPCM", narrowband_adpcm),
    ("Opus 32 kbit/s, 5% of chunks lost", opus_with_loss(32, 0.05, 7)),
]


# ------------------------------------------------------------------ scoring

def make_normalizer():
    try:
        from whisper_normalizer.english import EnglishTextNormalizer
        return EnglishTextNormalizer()
    except Exception:  # fall back to something simple
        return lambda s: re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", s.lower())).strip()


def word_errors(ref, hyp):
    """Substitutions + insertions + deletions (Levenshtein distance over words)."""
    r, h = ref.split(), hyp.split()
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hw in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw))
        prev = cur
    return prev[len(h)], len(r)


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model", default="base.en", help="Whisper model (default: base.en)")
    ap.add_argument("--voices", type=int, default=4, help="how many built-in voices to use")
    ap.add_argument("--recordings", help="folder of audio files with matching .txt transcripts")
    ap.add_argument("--snr", type=float, nargs="+", default=[10.0, 5.0],
                    help="speech-to-noise ratios in dB for the noisy passes (lower = louder noise)")
    ap.add_argument("--quick", action="store_true", help="first 6 lines and 2 voices only")
    args = ap.parse_args()

    if args.recordings:
        items = load_recordings(args.recordings)
        source = f"{len(items)} recordings from {args.recordings}"
    else:
        voices = available_voices(2 if args.quick else args.voices)
        if not voices:
            sys.exit("No suitable macOS voices found. Pass --recordings instead.")
        items = synthesize(voices, SCRIPT[:6] if args.quick else SCRIPT)
        source = (f"{len(items)} utterances: macOS voices {', '.join(v.split(' ')[0] for v in voices)} "
                  f"reading a {len(SCRIPT)}-line EMS script")
    if not items:
        sys.exit("No audio to test.")
    seconds = sum(len(i["pcm"]) for i in items) / SR
    items = group(items)
    print(f"{source}\n{seconds / 60:.1f} minutes of speech per condition, in {len(items)} clips\n", flush=True)

    from faster_whisper import WhisperModel
    model = WhisperModel(args.model, device="cpu", compute_type="int8", cpu_threads=8)
    normalize = make_normalizer()

    def transcribe(pcm):
        # temperature=0: no random fallback decoding, so repeated runs give the same transcript
        segments, _ = model.transcribe(pcm.astype(np.float32) / 32768.0, language="en", beam_size=5,
                                       condition_on_previous_text=False, temperature=0.0)
        return " ".join(s.text.strip() for s in segments)

    passes = [("clean", None)] + [(f"noise at {snr:g} dB", snr) for snr in args.snr]
    results = {name: {} for name, _ in passes}
    samples_dir = HERE / "results" / "samples"
    samples_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()

    for pass_name, snr in passes:
        rng = np.random.default_rng(1234)
        inputs = [i["pcm"] if snr is None else add_noise(i["pcm"], snr, rng) for i in items]
        raw_texts = None
        for cond_name, codec in CONDITIONS:
            errors = words = changed = 0
            rates, texts = [], []
            for item, pcm in zip(items, inputs):
                audio, rate = codec(pcm)
                rates.append(rate)
                hyp = normalize(transcribe(audio))
                texts.append(hyp)
                e, n = word_errors(normalize(item["text"]), hyp)
                errors += e
                words += n
            if raw_texts is None:
                raw_texts = texts
            else:
                changed = sum(a != b for a, b in zip(raw_texts, texts))
            # keep one example of each condition to listen to
            audio, _ = codec(inputs[0])
            tag = re.sub(r"[^a-z0-9]+", "-", cond_name.lower()).strip("-")
            level = "clean" if snr is None else f"noise-{snr:g}dB"
            wavfile.write(samples_dir / f"{level}--{tag}.wav", SR, audio)

            results[pass_name][cond_name] = {
                "bytes_per_sec": round(float(np.mean(rates))), "errors": errors, "words": words,
                "wer": errors / words, "clips_changed_vs_raw": changed, "clips": len(items)}
            r = results[pass_name][cond_name]
            print(f"[{time.time() - started:5.0f}s] {pass_name:26s} {cond_name:36s} "
                  f"{r['bytes_per_sec']:6d} B/s   WER {100 * r['wer']:5.1f}%  ({errors}/{words})", flush=True)

    # ---- report
    lines = ["# Compression vs transcript accuracy", "",
             f"Speech: {source}.", f"Recognizer: Whisper `{args.model}`. Budget: {BUDGET:,} bytes per second.", "",
             "Word error rate (WER) is the share of words the recognizer got wrong: lower is better.",
             "\"Change\" is the difference from raw audio in the same pass, in percentage points.",
             "Noise is simulated ambulance noise (engine rumble, hiss and a siren); the dB figure is how",
             "much louder the speech is than the noise, so 5 dB is the harsher case.", ""]
    names = [n for n, _ in passes]
    lines.append("| Audio sent | Bytes/s | Fits budget | " + " | ".join(f"WER, {n} | Change" for n in names) + " |")
    lines.append("|---|---|---|" + "---|---|" * len(names))
    for cond_name, _ in CONDITIONS:
        r0 = results[names[0]][cond_name]
        row = [cond_name, f"{r0['bytes_per_sec']:,}", "yes" if r0["bytes_per_sec"] <= BUDGET else "no"]
        for n in names:
            r = results[n][cond_name]
            base = results[n][CONDITIONS[0][0]]
            delta = 100 * (r["wer"] - base["wer"])
            row += [f"{100 * r['wer']:.1f}%", "baseline" if cond_name == CONDITIONS[0][0] else f"{delta:+.1f}"]
        lines.append("| " + " | ".join(row) + " |")
    lines += ["", f"Each cell is {results[names[0]][CONDITIONS[0][0]]['words']:,} words. "
              "One example of every condition is in `samples/` to listen to."]
    report = "\n".join(lines) + "\n"
    (HERE / "results" / "results.md").write_text(report)
    (HERE / "results" / "results.json").write_text(json.dumps(
        {"source": source, "model": args.model, "snr_db": args.snr, "results": results}, indent=2))
    print("\n" + report)
    print(f"Saved to {HERE / 'results'}  ({time.time() - started:.0f} s)")


if __name__ == "__main__":
    main()
