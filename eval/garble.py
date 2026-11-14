#!/usr/bin/env python3
"""Deterministic "garbled" copy of ground-truth transcripts, for the Phi recovery measurement.

Rewrites the way values are said, the way crews and speech recognition do, without changing any
value: the ground truth still applies. The rewrites target phrasings the rules extractor misses
(found by probing it), plus two misheard drug names that recovery must NOT accept.

  python3 eval/garble.py <gt segments.json> <out segments.json>
"""
import json, re, sys

RULES = [
    # vital-sign lead-ins the rules do not know
    (r"\bheart rate(?: is| of| at)?\b", "heart's going about"),
    (r"\b(?:sats|sat|SpO2|O2 sat|O2 sats|saturation)(?: is| are| of| at)?\b", "pulse ox says"),
    (r"\b(?:blood pressure|B ?P)(?: is| of)?\b", "pressure came back"),
    (r"\bGCS(?: is| of)?\b", "Glasgow"),
    (r"\b(?:resps|respirations|resp rate|respiratory rate)(?: are| is| of| at)?\b", "breathing's around"),
    # misheard drug names (recovery must send these to "please confirm", never accept them)
    (r"\baspirin\b", "a spurin"),
    (r"\bZofran\b", "so fran"),
]


def garble(text: str) -> str:
    for rx, rep in RULES:
        text = re.sub(rx, rep, text, flags=re.IGNORECASE)
    return text


if __name__ == "__main__":
    segs = json.load(open(sys.argv[1]))
    for s in segs:
        s["text"] = garble(s["text"])
    json.dump(segs, open(sys.argv[2], "w"), indent=1)
