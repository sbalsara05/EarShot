#!/usr/bin/env python3
"""Generate the fixed demo call: script -> espeak-ng speech -> 16 kHz WAV (to a
temp path you choose; never committed), plus taps.json and the ground-truth
transcript. Convert the WAV to a replay file with `earshot-eval make-replay`.

    python3 core/tools/make_demo_call.py /tmp/demo_call.wav mocks/demo_call
"""
import json, os, random, struct, subprocess, sys, tempfile, wave

LINES = [  # (start_s, text)
    (2.0, "We got called for a fall, but it turned out to be chest pain."),
    (9.0, "She is a sixty seven year old female, about seventy kilos."),
    (16.0, "Complaining of chest pressure radiating to the left arm, started an hour ago."),
    (25.0, "History of hypertension and diabetes. Allergic to penicillin. She takes metoprolol."),
    (36.0, "B P one fifty eight over ninety two, heart rate one ten, sats ninety four percent on room air, resps twenty two."),
    (52.0, "Three twenty four of aspirin, chewed."),
    (62.0, "Twelve lead shows S T elevation. Call a STEMI alert."),
    (74.0, "Eighteen gauge in the left A C."),
    (86.0, "Nitro point four sublingual."),
    (112.0, "Pain is a six out of ten now. She is compensating."),
    (122.0, "B P one thirty eight over eighty four, pulse ninety six, sats ninety seven on two liters."),
    (136.0, "Four milligrams of Zofran I V for nausea."),
    (146.0, "Transporting to Mass General, lights and sirens, E T A twelve minutes."),
    (158.0, "Okay, we're at the E D."),
]
TAPS = [
    {"clip_ms": 500, "source": "button", "gesture": "yes"},
    {"clip_ms": 52500, "source": "button"},
    {"clip_ms": 73000, "source": "button"},
    {"clip_ms": 86200, "source": "button"},
    {"clip_ms": 100000, "source": "button"},          # nothing said near it -> unlabeled
    {"clip_ms": 137000, "source": "button"},
    {"clip_ms": 160000, "source": "tablet", "gesture": "arrival"},
    {"clip_ms": 1360000, "source": "tablet", "gesture": "handoff"},  # nurse accept 20 min later
]
END_S = 166.0
RATE = 16000

def tts(text):
    with tempfile.TemporaryDirectory() as d:
        raw = os.path.join(d, "a.wav"); out = os.path.join(d, "b.wav")
        subprocess.run(["espeak-ng", "-v", "en-us", "-s", "155", "-w", raw, text], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ar", str(RATE), "-ac", "1", "-sample_fmt", "s16", out], check=True)
        with wave.open(out) as w:
            return list(struct.unpack("<%dh" % w.getnframes(), w.readframes(w.getnframes())))

def main():
    wav_path, out_dir = sys.argv[1], sys.argv[2]
    rnd = random.Random(7)
    n = int(END_S * RATE)
    buf = [int(rnd.gauss(0, 60)) for _ in range(n)]  # light background noise
    truth = []
    for i, (t, text) in enumerate(LINES):
        s = tts(text)
        a = int(t * RATE)
        for k, v in enumerate(s):
            if a + k < n:
                buf[a + k] = max(-32768, min(32767, buf[a + k] + v))
        truth.append({"id": "s%d" % (i + 1), "start_ms": int(t * 1000), "end_ms": int(t * 1000 + len(s) * 1000 / RATE), "text": text})
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % n, *buf))
    os.makedirs(out_dir, exist_ok=True)
    json.dump(TAPS, open(os.path.join(out_dir, "taps.json"), "w"), indent=1)
    json.dump(truth, open(os.path.join(out_dir, "transcript.truth.json"), "w"), indent=1)
    print("wrote", wav_path, len(truth), "lines")

main()
