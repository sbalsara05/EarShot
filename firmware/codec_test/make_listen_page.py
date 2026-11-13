#!/usr/bin/env python3
"""Build a page for listening to the compression test: codec_test/results/listen.html.

For one clip from the test it shows every setting side by side: an audio player, what Whisper
heard (wrong words marked), and that setting's overall score from results.json.

Run after compare.py (from firmware/):
  build/codec-test-venv/bin/python codec_test/make_listen_page.py
Then serve the results folder and open the page:
  python3 -m http.server 8770 --directory codec_test/results
  http://localhost:8770/listen.html
"""
import difflib
import html
import json
import pathlib
import re
import sys

import numpy as np
from scipy.io import wavfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compare  # noqa: E402

RESULTS = HERE / "results"


def tag(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def marked_transcript(ref_words, hyp_words):
    """What Whisper heard, with wrong or added words highlighted and missed words struck out."""
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ref_words, hyp_words, autojunk=False).get_opcodes():
        if op == "equal":
            out.append(html.escape(" ".join(hyp_words[j1:j2])))
        else:
            if i2 > i1:
                out.append(f'<del title="said, but not heard">{html.escape(" ".join(ref_words[i1:i2]))}</del>')
            if j2 > j1:
                out.append(f'<mark title="heard, but not said">{html.escape(" ".join(hyp_words[j1:j2]))}</mark>')
    return " ".join(out)


def main():
    data = json.loads((RESULTS / "results.json").read_text())
    results = data["results"]
    passes = list(results)                      # "clean", "noise at 10 dB", ...
    conditions = list(results[passes[0]])
    budget = compare.BUDGET

    from faster_whisper import WhisperModel
    model = WhisperModel(data["model"], device="cpu", compute_type="int8", cpu_threads=8)
    normalize = compare.make_normalizer()

    # The sample clip is the first clip of the test: recover what was actually said in it.
    voices = compare.available_voices(4)
    first = compare.group(compare.synthesize(voices, compare.SCRIPT))[0]
    ref_words = normalize(first["text"]).split()

    sections = []
    for pass_name in passes:
        level = "clean" if pass_name == "clean" else "noise-" + pass_name.split(" ")[2] + "dB"
        title = {"clean": "Clean speech"}.get(pass_name, pass_name.replace("noise at", "Ambulance noise, speech louder by"))
        rows = []
        for cond in conditions:
            wav = RESULTS / "samples" / f"{level}--{tag(cond)}.wav"
            if not wav.exists():
                continue
            _, pcm = wavfile.read(wav)
            segments, _ = model.transcribe(pcm.astype(np.float32) / 32768.0, language="en", beam_size=5,
                                           condition_on_previous_text=False, temperature=0.0)
            hyp_words = normalize(" ".join(s.text.strip() for s in segments)).split()
            errors, total = compare.word_errors(" ".join(ref_words), " ".join(hyp_words))
            r = results[pass_name][cond]
            fits = r["bytes_per_sec"] <= budget
            rows.append(f"""
      <article>
        <header>
          <h3>{html.escape(cond)}</h3>
          <span class="pill {'ok' if fits else 'no'}">{r['bytes_per_sec']:,} bytes/s · {'fits' if fits else 'over budget'}</span>
          <span class="pill">whole test: {100 * r['wer']:.1f}% wrong{'*' if r.get('note') else ''}</span>
          <span class="pill">this clip: {errors} of {total} words wrong</span>
        </header>
        <audio controls preload="none" src="samples/{wav.name}"></audio>
        <p class="heard">{marked_transcript(ref_words, hyp_words)}</p>{('<p class="note">* ' + html.escape(r['note']) + '</p>') if r.get('note') else ''}
      </article>""")
            print(f"{pass_name:16s} {cond:36s} {errors}/{total}", flush=True)
        sections.append(f"<section><h2>{html.escape(title)}</h2>{''.join(rows)}</section>")

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Compression test: listen</title>
<style>
  :root {{ --bg:#101317; --panel:#191e24; --line:#2a313a; --text:#e7ebf0; --dim:#8b96a3; --green:#2fd67b; --red:#ff6b6b; --amber:#ffb020; }}
  @media (prefers-color-scheme: light) {{ :root {{ --bg:#f6f7f9; --panel:#fff; --line:#d9dee5; --text:#16191d; --dim:#5d6875; --green:#0a8f4c; --red:#c62828; --amber:#9a6200; }} }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
  main {{ max-width: 900px; margin: 0 auto; padding: 20px 16px 60px; }}
  h1 {{ font-size: 22px; margin: 0 0 6px; }}
  h2 {{ font-size: 17px; margin: 34px 0 10px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }}
  h3 {{ font-size: 15px; margin: 0 8px 0 0; }}
  p.lead, .said {{ color: var(--dim); }}
  .said {{ background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }}
  article {{ background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; margin: 10px 0; }}
  article header {{ display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-bottom: 8px; }}
  .pill {{ font-size: 12px; border: 1px solid var(--line); border-radius: 999px; padding: 1px 9px; color: var(--dim); }}
  .pill.ok {{ color: var(--green); border-color: var(--green); }} .pill.no {{ color: var(--amber); border-color: var(--amber); }}
  audio {{ width: 100%; height: 36px; }}
  .heard {{ margin: 8px 0 0; font-size: 14px; }}
  mark {{ background: transparent; color: var(--red); font-weight: 600; }}
  del {{ color: var(--red); opacity: .75; }}
  .key span {{ margin-right: 14px; }}
  .note {{ margin: 6px 0 0; font-size: 13px; color: var(--amber); }}
</style></head><body><main>
  <h1>Compression test: listen for yourself</h1>
  <p class="lead">One clip from the test, sent every way the test tried. Press play to hear what the tablet would
  receive, and read what Whisper ({html.escape(data['model'])}) made of it. The percentages are from the whole
  test ({results[passes[0]][conditions[0]]['words']:,} words per setting), not just this clip.</p>
  <p class="key"><span><mark>red</mark> = heard but not said</span><span><del>struck out</del> = said but not heard</span></p>
  <h2>What was said</h2>
  <p class="said">{html.escape(first['text'])}</p>
  {''.join(sections)}
</main></body></html>
"""
    (RESULTS / "listen.html").write_text(page)
    print(f"\nWrote {RESULTS / 'listen.html'}")


if __name__ == "__main__":
    main()
