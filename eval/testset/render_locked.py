#!/usr/bin/env python3
"""GT-locked variant of data/synth/render.render(): same voices, rates, mic sim, tap hits and noise bed
(same seed, same rng draw order), but every speech segment, tap, distractor and triple knock is placed at the
time recorded in the ORIGINAL ground truth (data/scripts/test/gt/tts), and each Piper utterance is
time-stretched (librosa phase vocoder) to the original segment length. Needed because Piper's VITS sampling is
not seeded, so a plain re-render drifts by up to ~1 s against the original GT.
Usage: python render_locked.py <repo_root> <out_dir> [gt_dir]"""
import json, pathlib, sys
import numpy as np, soundfile as sf
ROOT = pathlib.Path(sys.argv[1]).resolve()
OUT = pathlib.Path(sys.argv[2]); OUT.mkdir(parents=True, exist_ok=True)
GTD = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else ROOT / "data/scripts/test/gt/tts"
sys.path.insert(0, str(ROOT / "data/synth"))
import calldsl, render, librosa
SR = render.SR


def fit(y, target):
    if len(y) != target and target > 0:
        y = librosa.effects.time_stretch(y, rate=len(y) / target)
    return np.pad(y, (0, max(0, target - len(y))))[:target].astype(np.float32)


def render_locked(call, gt_dir, seed, tb, snrs=(15, 10, 5), which_bank="test"):
    rng = np.random.default_rng(seed)
    cid = call["meta"]["call_id"]
    G = json.loads((gt_dir / f"{cid}.segments.json").read_text())
    T = json.loads((gt_dir / f"{cid}.taps.json").read_text())
    info = {r["call_id"]: r for r in json.loads((gt_dir / "render_info.json").read_text())}[cid]
    taps_gt = list(T["taps"]); ign = list(T["ignored"])
    pool = render.available_voices()
    order = list(rng.permutation(len(pool)))
    spk_voice = {s: pool[order[i % len(pool)]] for i, s in enumerate(["M1", "M2", "PT", "BY", "RD"])}
    rates = {s: rng.uniform(0.85, 1.05) for s in spk_voice}
    chunks = []; segs = []; stretch = []; si = 0
    for it in call["items"]:
        if it["kind"] == "tap":
            t = taps_gt.pop(0); assert t["source"] == it["source"]
            if it["source"] != "button":
                a = tb.multi(it["source"], 2, rng)
                chunks.append((int(t["clip_ms"] / 1000 * SR), a * (0.9 if it["source"] == "knock" else 0.6), False))
            if not it["labelled"]:
                d = ign.pop(0); assert d["kind"] == "single_ignored"
                a = tb.multi(d["source"], 1, rng)
                chunks.append((int(d["clip_ms"] / 1000 * SR), a * 0.7, False))
        elif it["kind"] == "triple":
            d = ign.pop(0); assert d["kind"] == "triple_stop"
            a = tb.multi("knock", 3, rng)
            chunks.append((int(d["clip_ms"] / 1000 * SR), a * 0.9, False))
        elif it["kind"] == "speech":
            g = G[si]; si += 1
            assert g["text"] == it["text"] and g["speaker"] == it["speaker"]
            v, sid = spk_voice[it["speaker"]]
            y = render.tts(it["text"], v, sid, rates[it["speaker"]])
            tail = int(0.1 * SR) if it["speaker"] in ("M2", "PT", "BY") else 0   # mic_sim reverb tail
            target = int(round((g["end_ms"] - g["start_ms"]) / 1000 * SR)) - tail
            stretch.append(len(y) / target)
            y = render.mic_sim(fit(y, target), it["speaker"], rng)
            chunks.append((int(g["start_ms"] / 1000 * SR), y, True))
            segs.append(dict(start_ms=g["start_ms"], end_ms=g["start_ms"] + int(len(y) / SR * 1000), speaker=g["speaker"], text=g["text"]))
            rng.uniform(0.3, 0.9)   # keep the rng stream identical to render.render (inter-segment gap draw)
    assert si == len(G) and not taps_gt and not ign
    n = int(round(info["seconds"] * SR))
    sp = np.zeros(n, np.float32); fx = np.zeros(n, np.float32)
    for s, a, is_sp in chunks:
        a = a[: n - s]; (sp if is_sp else fx)[s:s + len(a)] += a
    clean = sp + fx
    sf.write(OUT / f"{cid}.clean.wav", np.clip(clean, -1, 1), SR, subtype="PCM_16")
    bed = render.noise_bed(n, which_bank, rng)
    for snr in snrs:
        y = clean + render.mix_snr(sp, bed, snr)
        y = y / max(1.0, np.max(np.abs(y)) / 0.98)
        sf.write(OUT / f"{cid}.snr{snr}.wav", y, SR, subtype="PCM_16")
    (OUT / f"{cid}.segments.locked.json").write_text(json.dumps(segs, indent=1))
    return dict(call_id=cid, seconds=n / SR, voices={k: v[0] for k, v in spk_voice.items()},
                stretch_min=round(min(stretch), 4), stretch_max=round(max(stretch), 4))


tb = render.TapBank("test")
for i, f in enumerate(sorted((ROOT / "data/scripts/test").glob("c*.call"))):
    print(render_locked(calldsl.parse(f.read_text()), GTD, 100 + i, tb), flush=True)
