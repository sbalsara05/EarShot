#!/usr/bin/env python3
"""Same as data/synth/build_test_set.py (same seeds 100+i, same TapBank('test'), snrs 15/10/5) but the
regenerated ground truth goes to GT_OUT instead of overwriting data/scripts/test/gt/tts/.
Usage: python regen_test_set.py <repo_root> [gt_out_dir]"""
import json, pathlib, sys
ROOT = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(ROOT / "data/synth"))
import calldsl, render
AUD = ROOT / "data/audio/test/tts"
GT = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "data/scripts/test/gt/tts_regen"
GT.mkdir(parents=True, exist_ok=True)
tb = render.TapBank("test")
print("tap bank", len(tb.knock), "knock hits", len(tb.snap), "snap hits", flush=True)
info = []
for i, f in enumerate(sorted((ROOT / "data/scripts/test").glob("c*.call"))):
    call = calldsl.parse(f.read_text())
    assert not calldsl.validate_test_call(call), f
    r = render.render(call, AUD, "test", seed=100 + i, snrs=(15, 10, 5), tapbank=tb)
    for ext in ("transcript.txt", "transcript_speakers.txt", "segments.json", "events.jsonl", "taps.json", "expected.json"):
        (AUD / f"{r['call_id']}.{ext}").replace(GT / f"{r['call_id']}.{ext}")
    info.append(r); print(r, flush=True)
(GT / "render_info.json").write_text(json.dumps(info, indent=1))
