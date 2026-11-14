# Earshot app

The iPhone and iPad app. It records a call from the clip (or the device microphone when no clip is
connected), shows a live transcript with marks, then drafts a nurse handoff and a PCR for the medic
to edit and sign.

How it hears (see `docs/HYBRID.md`):

- **The record** comes from Whisper (whisper.cpp) running in the app, through the pipeline in
  `core/`: cleanup, rules that pick out vitals, drugs and treatments with the words they came from,
  and the chart, SOAP, IMIST-AMBO and NEMSIS outputs.
- **Live words** come from Apple's on-device speech recogniser while the medic talks. They are
  replaced by Whisper's lines a few seconds later, and used as a second opinion: where the two
  disagree on a drug, dose or vital sign, the draft says "please confirm". Optional: without it,
  recording still works.
- **The narrative** is written by a language model only if one is available (Apple Intelligence
  today; any model can be added behind `NoteWriter`). Optional: without it, every other line is
  still filled from the record.

## What you need

| | |
|---|---|
| Mac | Xcode 26 or later |
| Device or simulator | iOS or iPadOS 26 or later |
| Whisper | `scripts/fetch_deps.sh` builds whisper.xcframework and downloads a model (once, on the Mac) |
| For live words (optional) | A real iPhone or iPad with on-device speech recognition |
| For a written narrative (optional) | Apple Intelligence turned on. Everything else works without it |

## First time on a Mac

```bash
app/scripts/fetch_deps.sh
```

This builds whisper.cpp for iOS, downloads `ggml-small.en.bin` into `app/Models/`, and regenerates
`Earshot.xcodeproj` from `project.yml` (the pipeline package and new files are only in the project
after this step). A model can also be copied into the app's Documents folder from Finder.

## Run it in the simulator

1. Open `Earshot.xcodeproj` in Xcode.
2. Pick an iPhone or iPad simulator and press Run.

The simulator is good for checking screens and the flow. Two things do not work there:

- **Recording.** The simulator has no speech model, so a recording stops straight away with
  "Failed to initialize recognizer". That is expected.
- **The narrative.** It is only written if Apple Intelligence is turned on in the Mac's System
  Settings. Without it, the other lines are still filled from the record.

## Run it on a real iPhone or iPad

1. Plug the device into the Mac, unlock it and tap Trust.
2. On the device, turn on Developer Mode: Settings > Privacy & Security > Developer Mode, then restart.
3. Set your own signing team. In Xcode, select the Earshot target, open Signing & Capabilities, and
   choose your team. Change the bundle identifier to one of your own, since the committed one belongs
   to another account.
4. Pick the device in Xcode and press Run.
5. On first recording, allow Speech Recognition and the Microphone.

If Xcode says the device is not registered, or mentions the Program License Agreement, sign in at
developer.apple.com/account and accept the latest agreement, then run again.

To keep your team and bundle identifier between regenerations, set `DEVELOPMENT_TEAM` and
`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` instead (see below).

## Using it

1. **New call**, then **Start recording**. Speak; each pause starts a new line with its clock time.
2. **Mark** drops a numbered mark at that moment. The red button stops the recording.
3. Record again for another segment, or tap **Analyze** to draft the handoff and PCR.
4. Fix any line. Yellow lines are ones the AI did not hear.
5. **Sign off** by drawing a signature or typing your name. The call moves to Past calls on Home.

A call that is not signed stays open, even if the app is closed. To throw one away, use
**Discard call** on Home. Past calls open with a tap and delete with a swipe.

## Messages you may see

| Message | What it means |
|---|---|
| "No Whisper model is installed" | Run `scripts/fetch_deps.sh`, or copy `ggml-small.en.bin` into the app's Documents folder |
| "N item(s) need you to confirm them" | The two recognisers disagreed, or a value was suggested by the language model. Check the yellow lines |
| "Left out of the narrative because the record does not support them" | The language model wrote a number or drug that was not heard. It was removed |
| "This device cannot decode the clip's audio" | The system Opus decoder failed. See `Pipeline/OpusDecoder.swift` |

## Changing the project

`Earshot.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
You only need XcodeGen if you add or remove files, or change settings.

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

Run the second command inside `app/` after adding a Swift file, then commit both the file and the
regenerated project.

To build from the command line:

```bash
xcodebuild -project Earshot.xcodeproj -scheme Earshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Where things are

| File | What is in it |
|---|---|
| `Earshot/EarshotApp.swift` | App state, saving to disk, the header and tabs, Home, Clip |
| `Earshot/CallScreens.swift` | Live Call, AI Drafts, and the past-call screen |
| `Earshot/Recorder.swift` | The live recogniser (Apple, optional) and the microphone input |
| `Earshot/Pipeline/CallEngine.swift` | One call through the pipeline: clip or mic in, record and draft out |
| `Earshot/Pipeline/ClipLink.swift` | The interface the clip connection (Bluetooth) plugs into |
| `Earshot/Pipeline/OpusDecoder.swift` | The clip's Opus audio to samples |
| `Earshot/Pipeline/NoteWriter.swift`, `AppleNoteWriter.swift` | Optional narrative writer, any model |
| `../core/` | The pipeline (Swift package EarshotCore), shared with the eval tool and its tests |
| `Earshot/Signature.swift` | The sign-off sheet and signature drawing |
| `Earshot/Components.swift` | Colours, fonts, dot-matrix drawing, shared controls |
| `Earshot/Fonts/` | Doto and Geist, both under the Open Font License |

## Not built yet

- **The clip's Bluetooth connection.** Being written separately. It only needs to implement
  `ClipLink` (pass packets through untouched) and be set on `Model.link`; `CallEngine` does the
  rest. Until then the Clip tab is a stand-in and recordings use the microphone.
- **Not yet built or run on a device.** The app code for the pipeline was written without Xcode.
  The pipeline itself is tested (`cd core && swift test`), including against the firmware simulator.
- **Sign-in and audit trail.** Anyone holding the device can open the app and read past calls.
- **Audio.** Only the transcript is kept. No audio file is saved.
- **Long calls.** The on-device model reads about 4,000 tokens. Longer calls fail to draft with a
  message, and the handoff has to be filled in by hand.
- **Languages.** English (US) only.

Calls are stored only on the device, encrypted while it is locked, and kept out of iCloud backups.
Do not record real patients until the privacy and consent questions are settled for your service.
