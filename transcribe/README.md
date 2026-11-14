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

It builds the whisper.cpp framework (about ten minutes) and downloads `ggml-small.en` (465 MB). Neither is in the repo.

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
| Model | `small.en`, on the graphics chip | `Whisper.swift` |
| Candidates kept while writing (`beam`) | 5 | `Whisper.swift` |
| A chunk ends after | 0.7 s of quiet, or 25 s | `Chunker.swift` |
| Quietest sound sent to Whisper | about -55 dB, and 4 dB over the room | `Chunker.swift` |
| Drug names leaned toward | 321, in `Resources/drugs.txt` | `Bias.swift` |

## Try it on a Mac

```bash
swift run -c release transcribe-wav Models/ggml-small.en.bin call.wav
```

Prints each line with its confidence and its unsure words, then how long Whisper took. Add `--json` for the full shape.

```bash
swift test
```
