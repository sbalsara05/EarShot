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
        finish ─► Draft from the events
               └─► NoteWriter (any language model, optional) ─► narrative + suggested missed fields
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
| Bluetooth | `app/Earshot/ClipLink.swift` | with a clip | run on an iPad with the Feather stand-in |

## Rules of the record

- Whisper's text is the record. Apple's live words are display and a second opinion, never stored as the record.
- Only the rules put values in the chart. The language model may suggest vital signs and allergies,
  never medications, and only with a quote that is in the transcript.
- Anything heard by one recogniser but not the other, or suggested by the model, is "please confirm".
- No step needs Apple Intelligence. Without a writer, the narrative is left for the medic.

## Run the end-to-end check

```bash
core/scripts/setup_linux.sh        # or brew install whisper-cpp opus on a Mac
core/scripts/e2e_firmware.sh
```

It builds the firmware simulator (the real firmware core), plays the clip's built-in voice through
Opus over a WebSocket, records the capture (`core/tools/record_clip.py`), runs it through
`LiveSession` and Whisper, and prints the transcript next to the expected words.
