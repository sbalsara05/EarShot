#!/usr/bin/env python3
"""Measure the optional Phi-3.5-mini passes on ground-truth transcripts (no ASR), with the data team's
converter and scorer (approach of docs/pipeline/TEST_REPORT.md section 2).

  python3 eval/measure_llm.py --data ../earshot-data --out eval/runs/phi \\
      --set test --set dev --set test-garbled \\
      rules="" q4="--llm-model models/phi-3.5-mini-instruct-Q4_K_M.gguf" [q8="..."]

Sets: test (data/scripts/test/gt/tts), dev (data/scripts/dev_synth/gt), and either with "-garbled"
(eval/garble.py rewrites how values are said; the ground truth still applies). A variant can be limited
to some sets with name@set1+set2="args". Runs already done are reused (delete the folder to redo).
Writes <out>/summary.json and prints one block per (set, variant). Run variants one at a time: llama.cpp
and whisper threads slow each other down many times over.
"""
import argparse, glob, json, pathlib, shlex, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import garble as gb

ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True, help="earshot-data checkout, branch claude/eager-volta-za1pmi")
ap.add_argument("--out", required=True)
ap.add_argument("--set", action="append", required=True)
ap.add_argument("--threads", default="4")
ap.add_argument("variants", nargs="+", help='name[@set+set]="extra earshot-eval args"')
a = ap.parse_args()
data = pathlib.Path(a.data).resolve()
sys.path.insert(0, str(data / "eval"))
import run_pipeline as rp

SETS = {"test": data / "data/scripts/test/gt/tts", "dev": data / "data/scripts/dev_synth/gt"}
BIN = ROOT / "core/.build/release/earshot-eval"
root = pathlib.Path(a.out).resolve()
summary_path = root / "summary.json"
summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}

VITALS = ["bp_systolic", "bp_diastolic", "heart_rate", "resp_rate", "spo2", "glucose", "gcs", "pain"]


def run_set(setname, vname, extra):
    garbled = setname.endswith("-garbled")
    gt = SETS[setname.replace("-garbled", "")]
    out = root / setname / vname
    out.mkdir(parents=True, exist_ok=True)
    llm_s = 0.0; audio_s = 0.0; rss = 0.0; accepted = 0; rejected = 0; narr_used = 0; calls = 0
    for segf in sorted(gt.glob("*.segments.json")):
        uid = segf.name.split(".")[0]
        raw = out / "raw" / uid
        tj = json.loads((gt / f"{uid}.taps.json").read_text())
        segs = json.loads(segf.read_text())
        if garbled:
            for s in segs:
                s["text"] = gb.garble(s["text"])
        tr = out / f"{uid}.input.json"; tr.write_text(json.dumps(segs))
        taps = out / f"{uid}.taps.input.json"
        taps.write_text(json.dumps([dict(clip_ms=t["clip_ms"], source=t["source"], gesture="mark") for t in tj["taps"]]))
        if not (raw / "timing.json").exists():
            cmd = [str(BIN), "run", str(tr), "--taps", str(taps), "--dict", str(ROOT / "shared"), "--call-id", uid,
                   "--start", f"2026-11-15T{tj.get('start', '12:00:00')}-05:00", "--llm-threads", a.threads, "--out", str(raw)] + shlex.split(extra)
            t0 = time.time()
            p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
            if p.returncode:
                print("FAIL", setname, vname, uid, p.stderr[-400:]); continue
            print(f"  {setname}/{vname}/{uid}: {time.time() - t0:.0f} s", flush=True)
        rp.convert(uid, raw, out, gt)
        t = json.loads((raw / "timing.json").read_text())
        llm_s += sum(v for k, v in t["seconds"].items() if k.startswith("llm_"))
        rss = max(rss, t.get("peak_rss_mb", 0))
        audio_s += max(s["end_ms"] for s in segs) / 1000
        calls += 1
        lj = raw / "llm.json"
        if lj.exists():
            l = json.loads(lj.read_text())
            if l.get("recovery"): accepted += l["recovery"]["accepted"]; rejected += l["recovery"]["rejected"]
            if l.get("narrative", {}).get("used"): narr_used += 1
    sj = out / "score.json"
    subprocess.run([sys.executable, str(HERE / "run_score.py"), str(data), "--gt", str(gt), "--run", str(out), "--json", str(sj), "--quiet"],
                   check=True, capture_output=True)
    sc = json.loads(sj.read_text())
    ex, op = sc.get("extraction", {}), sc.get("outputs", {})
    fields = {k: {"p": v.get("precision"), "r": v.get("recall"), "f1": v.get("f1")} for k, v in ex.get("fields", {}).items()}
    return {
        "calls": calls, "audio_s": round(audio_s, 1),
        "llm_s": round(llm_s, 1), "added_s_per_audio_min": round(llm_s / (audio_s / 60), 1) if audio_s else None,
        "added_x_audio": round(llm_s / audio_s, 2) if audio_s else None, "peak_rss_mb": rss,
        "recovered_accepted": accepted, "recovered_rejected": rejected, "narrative_used": f"{narr_used}/{calls}",
        "fields": fields, "unsupported_field_rate": ex.get("unsupported_field_rate"), "unsupported": ex.get("unsupported"),
        "unsupported_examples": ex.get("unsupported_examples", [])[:10],
        "diagnosis_leaks": len(op.get("diagnosis_leaks", [])), "key_field_match": op.get("key_field_match"),
        "nemsis_valid": op.get("nemsis_schema_valid"),
    }


for spec in a.variants:
    head, extra = spec.split("=", 1)
    vname, _, only = head.partition("@")
    for setname in a.set:
        if only and setname not in only.split("+"):
            continue
        print(f"== {setname} / {vname}", flush=True)
        r = run_set(setname, vname, extra)
        summary.setdefault(setname, {})[vname] = r
        summary_path.write_text(json.dumps(summary, indent=1))
        f = r["fields"]
        print(f"   unsupported {r['unsupported_field_rate']}  leaks {r['diagnosis_leaks']}  nemsis {r['nemsis_valid']}  "
              f"llm {r['added_s_per_audio_min']} s/min audio ({r['added_x_audio']}x)  rss {r['peak_rss_mb']} MB  "
              f"recovered {r['recovered_accepted']} (+{r['recovered_rejected']} rejected)  narrative {r['narrative_used']}")
        print("   " + "  ".join(f"{k} {v['p']:.2f}/{v['r']:.2f}" for k, v in f.items() if v.get("p") is not None and v.get("r") is not None))
