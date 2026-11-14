# Transcribe

Audio in, transcript lines with a confidence out. Nothing else: no clean-up, no rules, no reports.

```
16 kHz audio ─► Chunker cuts at pauses ─► Whisper reads each chunk ─► Lines: one per sentence
   (clip or mic)        (Chunker.swift)        (Whisper.swift)            (Line.swift)
```

## Set up, once

```bash
./fetch.sh
```

It builds the whisper.cpp framework (about ten minutes, not in the repo) and pulls the model from Git LFS (488 MB;
needs `brew install git-lfs`).

## The model

`ggml-ems-small.en-ft-f16`: Whisper small.en fine-tuned on EMS speech, from pull request 15. It runs about ten
times faster than speech on an M1 iPad.

| Test | Stock small.en | Fine-tuned |
|---|---|---|
| Scripted call dense with EMS terms (Mac) | "steamy", "end title CO2", "Medik 4" | "STEMI", "end tidal CO2", "Medic 4" |
| Real call played to an iPad, words wrong | 26.7% | 28.1% (a tie at 645 words) |
| Punctuation | Kept | Often dropped, which gives long lines |

The stock model still works for comparing: put `ggml-small.en.bin` in `Models/` and bundle it in place of the
fine-tuned one (`app/project.yml`).

## What comes out

```json
{
  "startMs": 68600, "endMs": 70400,
  "text": "Blood pressure 158 over 94.",
  "confidence": 0.88,
  "words": [ { "offset": 0, "ms": 68600, "confidence": 0.97 }, ... ]
}
```

| Field | Meaning |
|---|---|
| `startMs`, `endMs` | When the first word began and the last ended, since the first sample |
| `confidence` | The average of the words' confidences, 0 to 1. Under 0.6 counts as unsure |
| `words` | Each word's place in `text`, when it was said, and its confidence |

## Where confidence comes from

1. Whisper writes text a word-piece at a time, and gives each piece a probability.
2. A word's confidence is the average of its pieces. Punctuation does not count.
3. A line's confidence is the average of its words.

It says how sure Whisper was, not whether it was right.

## Settings worth knowing

| Setting | Value | Where |
|---|---|---|
| Model | small.en fine-tuned on EMS speech, on the graphics chip | `Models/`, `Whisper.swift` |
| Candidates kept while writing (`beam`) | 5 | `Whisper.swift` |
| A chunk ends after | 0.7 s of quiet, or 25 s | `Chunker.swift` |
| Quietest sound sent to Whisper | about -55 dB, and 4 dB over the room | `Chunker.swift` |
| Drug names leaned toward | 321, in `Resources/drugs.txt` | `Bias.swift` |

## Try it on a Mac

```bash
swift run -c release transcribe-wav Models/ggml-ems-small.en-ft-f16.bin call.wav
```

Prints each line with its confidence and its unsure words, then how long Whisper took. Add `--json` for the full shape.

```bash
swift test
```
