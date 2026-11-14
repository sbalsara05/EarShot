#!/usr/bin/env python3
"""Score the pipeline on the test calls' ground-truth transcripts (no audio, no ASR): checks the
rules and cleanup on their own. Use it before and after a rules change to see what moved.

  python3 eval/score_transcripts.py --data <earshot-data checkout> --out eval/runs/gt_transcripts
"""
import argparse, json, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True); ap.add_argument("--out", required=True)
a = ap.parse_args()
data = pathlib.Path(a.data).resolve()
sys.path.insert(0, str(data / "eval"))
import run_pipeline as rp

gt = data / "data/scripts/test/gt/tts"
out = pathlib.Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=True)
for segf in sorted(gt.glob("c*.segments.json")):
    uid = segf.name.split(".")[0]
    raw = out / "raw" / uid; raw.mkdir(parents=True, exist_ok=True)
    tj = json.loads((gt / f"{uid}.taps.json").read_text())
    taps = out / f"{uid}.taps.input.json"
    taps.write_text(json.dumps([dict(clip_ms=t["clip_ms"], source=t["source"], gesture="mark") for t in tj["taps"]]))
    tr = out / f"{uid}.json"; tr.write_text(segf.read_text())
    p = subprocess.run([str(ROOT / "core/.build/release/earshot-eval"), "run", str(tr), "--taps", str(taps), "--dict", str(ROOT / "shared"),
                        "--call-id", uid, "--start", f"2026-11-15T{tj.get('start', '12:00:00')}-05:00", "--out", str(raw)],
                       capture_output=True, text=True)
    if p.returncode: print("FAIL", uid, p.stderr[-400:]); continue
    rp.convert(uid, raw, out, gt)
subprocess.run([sys.executable, str(HERE / "run_score.py"), str(data), "--gt", str(gt), "--run", str(out), "--json", str(out / "score.json")], check=True)
