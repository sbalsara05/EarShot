#!/usr/bin/env python3
"""Prompt-copy check: did the ASR copy numbers or dose phrases from the initial prompt?

For every call, counts numbers and dose phrases that appear in the PROMPT and in the
OUTPUT transcript but not in the REFERENCE transcript (beyond the reference count).
Any such hit is evidence of priming, not hearing. Use it in the ship decision:
a model (or prompt) is not shipped if its prompt-copy count is above the limit.

  python3 core/tools/prompt_copy_check.py --prompt-json shared/ems_terms.json \
      --run eval/runs/pipe_stock/test_tts_snr10 --gt data/scripts/test/gt/tts [--json out.json] [--max 0]

--run may hold <id>.hyp.txt files (eval/run_pipeline.py) or earshot-eval output folders
(<id>/transcript.raw.json, which also records the prompt actually used).
--gt holds <id>.transcript.txt. Exit code 1 if the total exceeds --max.
"""
import argparse, json, pathlib, re, sys
from collections import Counter

ONES = {"zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9}
TEENS = {"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
         "seventeen": 17, "eighteen": 18, "nineteen": 19}
TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}
UNITS = r"(?:mg|mcg|g|ml|cc|units?|meq|l|lpm|%|milligrams?|micrograms?|mics|migs|grams?|liters?)"


def words_to_digits(text):
    """Spoken numbers -> digits, same idea as the pipeline's cleanup ("three twenty four" -> 324,
    "point four" -> 0.4, "one twenty over eighty" -> 120 over 80)."""
    toks = re.findall(r"[a-z]+|\d+(?:\.\d+)?|[^\sa-z\d]", text.lower().replace("-", " "))
    out, i = [], 0

    def small(k):
        if k < len(toks) and toks[k] in TEENS: return TEENS[toks[k]], 1
        if k < len(toks) and toks[k] in TENS:
            if k + 1 < len(toks) and toks[k + 1] in ONES and ONES[toks[k + 1]] > 0: return TENS[toks[k]] + ONES[toks[k + 1]], 2
            return TENS[toks[k]], 1
        if k < len(toks) and toks[k] in ONES and toks[k] != "oh": return ONES[toks[k]], 1
        return None

    while i < len(toks):
        t = toks[i]
        if t == "point" and i + 1 < len(toks) and toks[i + 1] in ONES:
            s, k = "0.", i + 1
            while k < len(toks) and toks[k] in ONES: s += str(ONES[toks[k]]); k += 1
            out.append(s); i = k; continue
        r = small(i)
        if r is None: out.append(t); i += 1; continue
        v, n = r
        if toks[i] in ONES and n == 1 and i + 1 < len(toks):
            if toks[i + 1] == "hundred":
                v *= 100; n += 1
                r2 = small(i + n)
                if r2: v += r2[0]; n += r2[1]
            elif toks[i + 1] in TENS or toks[i + 1] in TEENS:
                r2 = small(i + 1); v = v * 100 + r2[0]; n = 1 + r2[1]
            elif toks[i + 1] == "oh" and i + 2 < len(toks) and toks[i + 2] in ONES:
                v = v * 100 + ONES[toks[i + 2]]; n = 3
        if i + n < len(toks) and toks[i + n] == "point" and i + n + 1 < len(toks) and toks[i + n + 1] in ONES:
            s, k = f"{v}.", i + n + 1
            while k < len(toks) and toks[k] in ONES: s += str(ONES[toks[k]]); k += 1
            out.append(s); i = k; continue
        out.append(str(v)); i += n
    return " ".join(out)


def norm(text):
    t = words_to_digits(text)
    t = re.sub(r"(\d)\s*/\s*(\d)", r"\1/\2", t)
    t = re.sub(r"(\d+)\s+over\s+(\d+)", r"\1/\2", t)
    return re.sub(r"\s+", " ", t)


def prompt_items(prompt):
    """Numbers (incl. BP pairs) and dose phrases ('<n> <unit>', '<drug> <n>') in the prompt."""
    p = norm(prompt)
    items = Counter()
    for m in re.finditer(r"\d+/\d+|\d+(?:\.\d+)?", p):
        items[("number", m.group(0))] += 1
    for m in re.finditer(r"(\d+(?:\.\d+)?)\s*" + UNITS + r"\b", p):
        items[("dose", m.group(0).replace(" ", ""))] += 1
    for m in re.finditer(r"\b([a-z][a-z\-]+)\s+(\d+(?:\.\d+)?)", p):
        items[("drug_dose", f"{m.group(1)} {m.group(2)}")] += 1
    return items


def count(text, kind, value):
    t = norm(text)
    if kind == "number":
        return len(re.findall(r"(?<![\d./])" + re.escape(value) + r"(?![\d/]|\.\d)", t))
    if kind == "dose":
        num = re.match(r"\d+(?:\.\d+)?", value).group(0)
        unit = value[len(num):]
        return len(re.findall(r"(?<![\d.])" + re.escape(num) + r"\s*" + re.escape(unit) + r"\b", t))
    return len(re.findall(r"\b" + re.escape(value) + r"(?![\d.])", t))


def load_hyp(run, uid):
    p = run / f"{uid}.hyp.txt"
    if p.exists(): return p.read_text(), None
    raw = run / uid / "transcript.raw.json"
    if raw.exists():
        j = json.loads(raw.read_text()); return " ".join(s["text"] for s in j["segments"]), j.get("initial_prompt")
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt"); ap.add_argument("--prompt-json"); ap.add_argument("--run", required=True); ap.add_argument("--gt", required=True)
    ap.add_argument("--json"); ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    run, gt = pathlib.Path(a.run), pathlib.Path(a.gt)
    prompt = a.prompt or (json.loads(pathlib.Path(a.prompt_json).read_text()).get("initial_prompt") if a.prompt_json else None)
    ids = sorted({p.name.split(".")[0] for p in gt.glob("*.transcript.txt")})
    per_call, total, hits = {}, 0, Counter()
    for uid in ids:
        hyp, used = load_hyp(run, uid)
        if hyp is None: continue
        pr = used or prompt
        if not pr: sys.exit("no prompt: pass --prompt/--prompt-json or use earshot-eval outputs (they record it)")
        ref = (gt / f"{uid}.transcript.txt").read_text()
        n = 0
        for (kind, value), _ in prompt_items(pr).items():
            extra = max(0, count(hyp, kind, value) - count(ref, kind, value))
            if extra: hits[f"{kind}:{value}"] += extra; n += extra
        per_call[uid] = n; total += n
    res = dict(prompt_copies=total, per_call=per_call, by_item=dict(hits.most_common()), calls=len(per_call), limit=a.max,
               verdict="PASS" if total <= a.max else "FAIL: output contains prompt values not in the reference")
    print(json.dumps(res, indent=1))
    if a.json: pathlib.Path(a.json).write_text(json.dumps(res, indent=1))
    sys.exit(0 if total <= a.max else 1)


if __name__ == "__main__":
    main()
