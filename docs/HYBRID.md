# How Earshot hears: the hybrid

Two recognisers with different jobs, rules that own the record, and an optional language model that
is held to the transcript.

```
clip (Opus, firmware/BLUETOOTH.md) ─┐
iPad mic (no clip connected) ───────┴─► CallEngine decodes once
        ├─► Apple speech (on device, optional) ─► live words on screen (temporary)
        │                                          └─► second opinion (cross-check)
        └─► LiveSession (core/): Whisper ─► cleanup ─► rules ─► events ─► chart, SOAP, IMIST-AMBO, NEMSIS
                                                         ▲
             cross-check: Apple's words go through the same cleanup and rules; where the two
             disagree on a drug, dose or vital sign near the same moment, the event is "please confirm"
        finish ─► Phi-3.5-mini (llama.cpp, optional, off by default; after Whisper has drained)
               │     ├─► recovery: values the rules missed ─► RecoveryVerifier (span, verbatim quote, value in
               │     │     quote, formulary, ranges) ─► accepted → events (flag llm) · rejected → "please confirm"
               │     └─► narrative citing events ─► NarrativeChecker ─► passes → narrative · fails → template
               ─► Draft from the events
               └─► NoteWriter (any language model, optional; skipped when Phi wrote the narrative) ─► narrative + suggested missed fields
                     └─► Grounding: suggestions must quote the transcript; narrative sentences with a
                         number or drug not in the record are dropped; anything accepted is "please confirm"
```

| Part | Where | Required? | Tested here |
|---|---|---|---|
| Clip protocol, captures, gaps, reconnects | `core/Sources/EarshotCore/Wire/ClipProtocol.swift`, `LiveSession` | yes | `ClipProtocolTests`, `core/scripts/e2e_firmware.sh` |
| Whisper record | `core/Sources/EarshotWhisper` | yes (a model file) | end-to-end script with base.en |
| Rules, outputs | `core/Sources/EarshotCore` | yes | 98 tests |
| Cross-check | `core/Sources/EarshotCore/Hybrid/CrossCheck.swift` | no: needs live words | `HybridTests` |
| Grounding | `core/Sources/EarshotCore/Hybrid/Grounding.swift` | no: needs a writer | `HybridTests` |
| Live words | `app/Earshot/Recorder.swift` (`LiveRecognizer`) | no | needs a device |
| Opus on iOS | `app/Earshot/ClipLink.swift` (swift-opus) | yes, with a clip | needs a device |
| Narrative writer | `app/Earshot/Pipeline/NoteWriter.swift` (Apple's model today) | no | needs a device |
| Phi recovery + narrative | `core/Sources/EarshotCore/LLM` (verifier, checker), `core/Sources/EarshotLLM` (llama.cpp), `app/Earshot/Pipeline/PhiSlot.swift` | no (off by default; setting on the Clip tab) | `LLMTests` (stub), `PhiModelTests` (real model), `eval/measure_llm.py` |
| Bluetooth | `app/Earshot/ClipLink.swift` | with a clip | run on an iPad with the Feather stand-in |

## Rules of the record

- Whisper's text is the record. Apple's live words are display and a second opinion, never stored as the record.
- Only the rules put values in the chart, with one exception: a value Phi recovers that the verifier proves
  is in the transcript (its span, a verbatim quote, the value in that quote, a formulary drug, a plausible
  range) is added as heard, flagged `llm`, with the quote as its receipt. Phi never writes XML or a field
  directly (`docs/pipeline/DECISIONS.md` 32–37).
- The NoteWriter may suggest vital signs and allergies, never medications, and only with a quote that is in
  the transcript.
- Anything heard by one recogniser but not the other, or suggested by the model, is "please confirm".
- No step needs Apple Intelligence. Without a writer, the narrative is left for the medic.
- Whisper and Phi never run at the same time: they take turns on one lock (`ModelTurn`), one model call each.

## Run the end-to-end check

```bash
core/scripts/setup_linux.sh        # or brew install whisper-cpp opus on a Mac
core/scripts/e2e_firmware.sh
```

It builds the firmware simulator (the real firmware core), plays the clip's built-in voice through
Opus over a WebSocket, records the capture (`core/tools/record_clip.py`), runs it through
`LiveSession` and Whisper, and prints the transcript next to the expected words.
