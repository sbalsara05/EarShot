import json, pathlib, sys
ref, new = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
print("call nseg  maxd_start maxd_end  mean|d|  final_end_drift  text_same  taps_maxd  events_maxd")
for i in range(1, 11):
    c = f"c{i:02d}"
    a = json.loads((ref / f"{c}.segments.json").read_text()); b = json.loads((new / f"{c}.segments.json").read_text())
    assert len(a) == len(b)
    same = all(x["text"] == y["text"] and x["speaker"] == y["speaker"] for x, y in zip(a, b))
    ds = [y["start_ms"] - x["start_ms"] for x, y in zip(a, b)]; de = [y["end_ms"] - x["end_ms"] for x, y in zip(a, b)]
    ta = json.loads((ref / f"{c}.taps.json").read_text()); tb = json.loads((new / f"{c}.taps.json").read_text())
    tm = max([abs(x["clip_ms"] - y["clip_ms"]) for x, y in zip(ta["taps"] + ta["ignored"], tb["taps"] + tb["ignored"])] or [0])
    ea = [json.loads(l) for l in (ref / f"{c}.events.jsonl").read_text().splitlines()]
    eb = [json.loads(l) for l in (new / f"{c}.events.jsonl").read_text().splitlines()]
    em = max(abs(x["clip_ms"] - y["clip_ms"]) for x, y in zip(ea, eb))
    exp_same = json.loads((ref / f"{c}.expected.json").read_text()) == json.loads((new / f"{c}.expected.json").read_text())
    print(f"{c} {len(a):4d} {max(map(abs, ds)):10d} {max(map(abs, de)):8d} {sum(map(abs, ds + de)) / len(ds + de):8.0f} {de[-1]:+15d}  {same}  {tm:9d} {em:11d} expected_same={exp_same}")
