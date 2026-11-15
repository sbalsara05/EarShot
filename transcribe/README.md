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

It builds the whisper.cpp framework (about ten minutes, not in the repo) and pulls the model from Git LFS (175 MB;
needs `brew install git-lfs`).

## The model

`ggml-ems-small.en-ft-q5_0`: Whisper small.en fine-tuned on EMS speech, from pull request 15, stored at about five
bits a number. It runs about ten times faster than speech on an M1 iPad.

Three models were tried on one real call, played to an iPad and scored against a transcript of 645 words:

| | Stock small.en | Fine-tuned, full size (f16) | Fine-tuned, compressed (q5_0) |
|---|---|---|---|
| Size | 465 MB | 488 MB | 175 MB |
| Words wrong | 26.7% | 28.1% | 23.6% |
| Lines under the 0.6 bar | 4 | 0 | 7, of which 5 were real mistakes |
| Lines over 40 words | 0 | 3 | 1 |

One run each, so the gaps are a guide and not proof. On a scripted call dense with EMS terms, the fine-tuned model
wrote "STEMI", "end tidal CO2" and "Medic 4" where stock wrote "steamy", "end title CO2" and "Medik 4". The
fine-tuned models often drop punctuation, which gives some long lines.

To try another model, put its file in `Models/`, name it first in `Record.models` and bundle it in `app/project.yml`.

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
| Quiet audio is turned up | until speech peaks near -9 dB, up to 36 dB, without lifting room noise past -47 dB | `Level.swift` |
| Quietest sound sent to Whisper | about -55 dB, and 4 dB over the room | `Chunker.swift` |
| Drug names leaned toward | 321, in `Resources/drugs.txt` | `Bias.swift` |

## Try it on a Mac

```bash
swift run -c release transcribe-wav Models/ggml-ems-small.en-ft-q5_0.bin call.wav
```

Prints each line with its confidence and its unsure words, then how long Whisper took. Add `--json` for the full shape.

```bash
swift test
```
