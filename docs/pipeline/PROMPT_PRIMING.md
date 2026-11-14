# Prompt priming: the initial prompt is removed

**Whisper runs with no initial prompt, for every model** (the fine-tuned EMS model, and stock
small.en when it is run in eval for comparison). Nothing in the app, in `earshot-eval` or in any
default config passes one. Decision 27 in `DECISIONS.md`.

## Why it was removed
Whisper's initial prompt can leak into the transcript: a value written in the prompt can appear in
the output even when nobody said it. On an ePCR that is a made-up value. The last prompt was made
"format-only" to contain that risk (vocabulary and style, physically impossible numbers). Measured
with the fine-tuned model it bought nothing and still leaked:

| | No prompt | Format-only prompt |
|---|---|---|
| Fine-tuned, real speech: WER | 7.3% | 7.3% |
| Fine-tuned, 30 radio-style calls: drug-name WER | 31.5% | 31.5% |
| Prompt copies, radio-call set | 0 | 1 (in both prompted runs) |
| Stock small.en, real speech: WER | 11.3% | 13.2% (worse) |

The prompt was the only source of prompt copies, gave the fine-tuned model no gain, and made stock
worse. So it went, rather than being tuned again.

Reference results with no prompt (transformers, beam 5, same clips): real speech (315 clips) WER
11.3% → 7.3% and drug-name WER 42.7% → 30.9% (stock → fine-tuned); 30 radio-style calls with unseen
voices, drug-name WER 42.7% → 31.5%.

## What enforces it
- The `Transcriber` protocol has no prompt parameter: `transcribe(_ pcm: [Float])`. There is no
  path for prompt text to reach a recogniser.
- `WhisperTranscriber.decodeParams` leaves `initial_prompt` and `prompt_tokens` unset;
  `EarshotWhisperTests/NoPromptDecoderTests` checks this for beam and greedy, with and without
  temperature fallback (it replaces `PromptFreezeTests`).
- `shared/ems_terms.json` has no `initial_prompt`; `NoInitialPromptTests` checks the file, that old
  config keys (`use_initial_prompt`, `prompt`) are ignored, and that `transcript.raw.json` records no
  prompt.
- `earshot-eval --prompt-file` now fails with a message; `--no-prompt` is accepted and does nothing.
- `initial_prompt_core` in `ems_terms.json` stays: it is only the word list given to Apple's live
  recogniser as `contextualStrings`, never a Whisper prompt. The key keeps its old name.

## Prompt-copy check (kept as a guard)
`core/tools/prompt_copy_check.py` counts numbers and dose phrases that are in a prompt and in the
output but not in the reference transcript:
```bash
python3 core/tools/prompt_copy_check.py --run <run dir> --gt data/scripts/test/gt/tts --json copies.json --max 0
```
With no prompt given or recorded it checks against `RETIRED_PROMPT`, the last prompt shipped. Its
numbers are impossible (BP 61/127, HR 913), so a hit means a stale build or model is still priming.
It should always report 0. The data team's scorer (`earshot-data/eval/prompt_copy.py`) reads
`initial_prompt` from `ems_terms.json` and from each run's `transcript.raw.json`; both are gone, so
it scores against an empty prompt and reports 0.

## The retired prompt, for the record
> EMS call. Patient A&O, GCS. BP 61/127, HR 913, resps 113, sats 113%, BGL 913, ETCO2 213. Aspirin mg PO, nitro mg SL, Narcan mg IN, D10, glucagon, albuterol, DuoNeb, epi mg IM, Benadryl, Solu-Medrol, Zofran mg IV, fentanyl mcg, Versed, Ativan, amiodarone, adenosine, TXA. 12-lead, STEMI, IV, IO, CPAP, BVM, c-collar.
