# Measuring the pipeline

Scripts to score the pipeline (`core/`, `earshot-eval`) on the data team's 10 synthetic test calls,
with the data team's own scorer. Results so far are in `docs/BIASING.md`.

## What you need

- A checkout of **earshot-data, branch `claude/eager-volta-za1pmi`**: the test-call scripts, ground
  truth, renderer and scorer live there.
  ```bash
  git clone -b claude/eager-volta-za1pmi https://github.com/shourya0523/earshot-data ../earshot-data
  ```
- `earshot-eval` built in release: `cd core && swift build -c release`
- A Whisper model, e.g. `models/ggml-small.en.bin` (the data team's model):
  ```bash
  curl -L -o models/ggml-small.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
  ```
- Python for scoring: `pip install jiwer soundfile`
- Python for rendering audio (separate venv is easiest): `pip install piper-tts==1.8.0 librosa soundfile scipy numpy`

## 1. Make the test-call audio

The data team did not commit their audio. `eval/testset/` regenerates it with the same Piper voices,
noise and tap sounds (downloaded from the URLs and checksums in their manifest, about 1.2 GB):

```bash
python eval/testset/fetch_needed.py ../earshot-data
```

```bash
python eval/testset/render_locked.py ../earshot-data ../earshot-data/data/audio/test/tts_gtlocked
```

`render_locked.py` places every line at the time in the original ground truth and time-stretches it
to fit (most lines within ±8%), so the scorer's timing and tap checks stay valid. A plain re-render
(`regen_test_set.py`) drifts by up to ~1 s, because Piper is not seeded; only use it with the ground
truth it writes (`gt/tts_regen`). `compare_gt.py` reports that drift. Each render takes ~30 s.

## 2. Score variants

```bash
python3 eval/measure.py --data ../earshot-data --model models/ggml-small.en.bin \
  --wavs '../earshot-data/data/audio/test/tts_gtlocked/c*.snr10.wav' --out eval/runs/snr10 \
  nobias="--no-bias" bias=""
```

Each `name="args"` is one variant (any `earshot-eval` options). On a Mac add `--gpu` to every variant
for speed; compare only variants run the same way. Prints WER, drug-name WER, number accuracy, drug
precision/recall, dose recall, prompt copies and confidence flags, and lists the missed drug words.
Runs already done are reused. On a 4-core Linux VM, one variant takes ~15 min on CPU. **Never run two
at once on the same machine**: Whisper's threads spin while waiting and both slow down many times over.

## 3. Rules only (no audio)

```bash
python3 eval/score_transcripts.py --data ../earshot-data --out eval/runs/gt_transcripts
```

Runs the pipeline on the correct transcripts, so it measures cleanup and rules alone. Use it before
and after a rules change.

## Files

| File | What it does |
|---|---|
| `measure.py` | Variants on audio -> data team's converter and scorer -> summary |
| `score_transcripts.py` | Same on the ground-truth transcripts (no ASR) |
| `run_score.py` | Runs the data team's `eval/score.py` with its hardcoded formulary path pointed at this repo's `shared/` |
| `testset/fetch_needed.py` | Downloads the voices, noise and tap sounds the test set needs (checksummed) |
| `testset/render_locked.py` | Renders the test calls locked to the original ground truth |
| `testset/regen_test_set.py` | Plain re-render, with its own ground truth |
| `testset/compare_gt.py` | Timing drift between two ground-truth folders |
