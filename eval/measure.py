#!/usr/bin/env python3
"""Run earshot-eval variants on the test-call audio and score them with the data team's scorer.

  python3 eval/measure.py --data <earshot-data checkout> --wavs '<glob>' --model models/ggml-small.en.bin \\
      --out eval/runs/snr10 nobias="--no-bias" bias="" [more name="extra earshot-eval args" ...]

Each variant is run on every WAV (skipped if already done), converted with the data team's
eval/run_pipeline.py, and scored with eval/run_score.py. Prints one line per variant and writes
<out>/summary.json. Needs: core built in release (swift build -c release), python with jiwer + soundfile.
On a Mac, add --gpu to the variant args for speed (compare variants run the same way).
"""
import argparse, glob, json, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True, help="checkout of earshot-data, branch claude/eager-volta-za1pmi")
ap.add_argument("--wavs", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--gt", help="ground truth folder (default <data>/data/scripts/test/gt/tts)")
ap.add_argument("variants", nargs="+", help='name="extra args"')
a = ap.parse_args()

data = pathlib.Path(a.data).resolve()
sys.path.insert(0, str(data / "eval"))
import run_pipeline as rp          # the data team's converter to their GT event format

gt = pathlib.Path(a.gt) if a.gt else data / "data/scripts/test/gt/tts"
BIN = ROOT / "core/.build/release/earshot-eval"
wavs = sorted(glob.glob(a.wavs))
assert wavs, f"no WAVs match {a.wavs}"
root = pathlib.Path(a.out); rows = []
for spec in a.variants:
    name, extra = spec.split("=", 1)
    out = root / name; out.mkdir(parents=True, exist_ok=True)
    flagged = 0
    for w in wavs:
        uid = pathlib.Path(w).name.split(".")[0]
        raw = out / "raw" / uid
        if not (raw / "events.json").exists():
            raw.mkdir(parents=True, exist_ok=True)
            tj = json.loads((gt / f"{uid}.taps.json").read_text())
            taps = out / f"{uid}.taps.input.json"
            taps.write_text(json.dumps([dict(clip_ms=t["clip_ms"], source=t["source"], gesture="mark") for t in tj["taps"]]))
            cmd = [str(BIN), "run", w, "--taps", str(taps), "--asr-model", a.model, "--dict", str(ROOT / "shared"), "--call-id", uid,
                   "--start", f"2026-11-15T{tj.get('start', '12:00:00')}-05:00", "--out", str(raw)] + extra.split()
            p = subprocess.run(cmd, capture_output=True, text=True)
            if p.returncode: print("FAIL", name, uid, p.stderr[-300:]); continue
        rp.convert(uid, raw, out, gt)
        flagged += sum("low_confidence" in (e.get("flags") or []) for e in json.loads((raw / "events.json").read_text()))
    js = root / f"{name}.score.json"
    subprocess.run([sys.executable, str(HERE / "run_score.py"), str(data), "--gt", str(gt), "--run", str(out.resolve()),
                    "--json", str(js.resolve()), "--quiet"], check=True)
    s = json.loads(js.read_text())
    t, f = s["transcription"], s["extraction"]["fields"]
    r = dict(name=name, wer=t["wer"], drug_wer=t["drug_wer"], number_acc=t["number_acc"],
             drug_p=f["drug"]["precision"], drug_r=f["drug"]["recall"], dose_r=f["dose"]["recall"],
             unsupported=s["extraction"]["unsupported_field_rate"], prompt_copies=s.get("prompt_copy", {}).get("prompt_copies"),
             low_conf_flags=flagged, drug_misses=sorted({m for x in t["per_file"] for m in x.get("drug_misses", [])}))
    rows.append(r)
    print(f"{name:14} WER {r['wer']:.3f}  drugWER {r['drug_wer']:.3f}  numbers {r['number_acc']:.3f}  drug P/R {r['drug_p']:.2f}/{r['drug_r']:.2f}  "
          f"dose R {r['dose_r']:.2f}  unsupported {r['unsupported']:.3f}  prompt copies {r['prompt_copies']}  low-conf flags {flagged}", flush=True)
    for m in r["drug_misses"]: print("     miss:", m)
(root / "summary.json").write_text(json.dumps(rows, indent=1))
