# Prompt priming: rules and the stock vs fine-tuned comparison

Whisper's initial prompt can leak into the transcript: a value written in the prompt (say "aspirin 324 mg") can appear in the output even when nobody said it. On an ePCR that would be a made-up value, so the prompt and the evaluation are set up to rule it out.

## 1. The prompt is format-only
`shared/ems_terms.json` → `initial_prompt`:

> EMS call. Patient A&O, GCS. BP 61/127, HR 913, resps 113, sats 113%, BGL 913, ETCO2 213. Aspirin mg PO, nitro mg SL, Narcan mg IN, D10, glucagon, albuterol, DuoNeb, epi mg IM, Benadryl, Solu-Medrol, Zofran mg IV, fentanyl mcg, Versed, Ativan, amiodarone, adenosine, TXA. 12-lead, STEMI, IV, IO, CPAP, BVM, c-collar.

- It keeps vocabulary, abbreviations and the "name value unit route" style.
- Doses have units but no amounts.
- Every number is physically impossible: diastolic above systolic, SpO2 over 100, HR 913. None of them appears in any test or dev call, as digits or words (checked against the answer keys).
- Every number is also outside the extractor's plausibility ranges, so a copied value can never become a field. `testPromptValuesCannotBecomeFields` pins this.
- "12-lead" is kept: it is a term, not a reading.

## 2. Prompt-copy check (part of the ship decision)
`core/tools/prompt_copy_check.py` counts numbers and dose phrases that are in the prompt and in the output, but not in the reference transcript:
```bash
python3 core/tools/prompt_copy_check.py --run <run dir> --gt data/scripts/test/gt/tts --json copies.json --max 0
```
- It reads the prompt each earshot-eval run actually used (`transcript.raw.json` → `initial_prompt`), or takes `--prompt` / `--prompt-json`.
- It normalises spoken numbers ("three twenty four" → 324, "one forty two over eighty eight" → 142/88), so references written in words still match.
- It exits 1 when copies exceed `--max`.
- **Ship rule:** a model/prompt combination ships only with **0 prompt copies** on the test calls, in addition to the accuracy gate.

## 3. Stock vs fine-tuned: compare without priming
Run both models on the same test calls under two prompt conditions:

| Condition | Flag | Why |
|---|---|---|
| Neutral (no prompt) | `--no-prompt` | Any gain must come from the model, not from priming. **This one decides.** |
| Format-only prompt | (default) | What the app will actually run. |

```bash
for m in stock ft; do
  model=$([ $m = stock ] && echo models/ggml-small.en.bin || echo models/whisper-ems-small.en-q5.bin)
  python3 eval/run_pipeline.py --wavs 'data/audio/test/tts/c*.snr10.wav' --gt data/scripts/test/gt/tts \
     --out eval/runs/ab_${m}_noprompt --asr-model $model --extra-args "--no-prompt"
  python3 eval/run_pipeline.py --wavs 'data/audio/test/tts/c*.snr10.wav' --gt data/scripts/test/gt/tts \
     --out eval/runs/ab_${m}_format --asr-model $model
done
```
Score each with `eval/score.py` and `prompt_copy_check.py` (pass `--prompt-json shared/ems_terms.json` for `run_pipeline.py` outputs).

**Ship the fine-tuned model only if:**
1. it beats stock with **no prompt**, and
2. it is not worse than stock with the format-only prompt, and
3. both of its runs have 0 prompt copies.

## Note on the Kaggle run
The notebook trains with whatever `initial_prompt` is on `overnight` **when it clones**. A run started before this change trained with the older prompt, which contained real-looking values ("aspirin 324 mg", "BP 142/88"). For such a model the no-prompt comparison above is the fair test. To train on the format-only prompt, start a new run.
