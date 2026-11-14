#!/usr/bin/env python3
"""Run the data team's scorer (earshot-data: eval/score.py) with its formulary path pointed here.

score.py reads the pipeline formulary from a hardcoded /home/user/pipeline/shared to map drug names
onto its ground-truth names; without it, drug scores are wrong. This runs score.py unchanged except
for that one path, which becomes EARSHOT_SHARED (default: this repo's shared/).

  python3 eval/run_score.py <earshot-data checkout> --gt ... --run ... [--json ...] [--quiet]
"""
import os, pathlib, sys

data = pathlib.Path(sys.argv[1]).resolve()
shared = os.environ.get("EARSHOT_SHARED", str(pathlib.Path(__file__).resolve().parents[1] / "shared"))
os.environ["EARSHOT_SHARED"] = shared          # also read by eval/prompt_copy.py
score = data / "eval" / "score.py"
src = score.read_text().replace("/home/user/pipeline/shared", shared)
sys.argv = [str(score)] + sys.argv[2:]
os.chdir(data)
g = {"__name__": "__main__", "__file__": str(score)}
exec(compile(src, str(score), "exec"), g)
