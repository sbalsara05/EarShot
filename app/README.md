# Earshot app

The iPhone and iPad app. It records a call, shows a live transcript with marks, then drafts a nurse
handoff and a PCR for the medic to edit and sign.

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

It connects to the clip over Bluetooth, following [`firmware/BLUETOOTH.md`](../firmware/BLUETOOTH.md).
The link lives in `Earshot/ClipLink.swift`. It has been run against the ESP32-S3 Feather stand-in on an
iPad, not yet against the Atom VoiceS3R.

## Using a clip

1. Power the clip. On the Clip tab, tap **Find my clip** and allow Bluetooth. Clips in range are
   listed with their signal strength; tap yours to connect. The app remembers it and reconnects by
   itself from then on. **Find clip** makes a connected clip blink.
2. The clip's button then drives the call:

| On the clip | In the app |
|---|---|
| Click | Drops a mark |
| Double click | Pauses the recording, or resumes it |
| Click and hold | Completes the open call. With no call open, starts one and begins recording |

**Audio from** on the Clip tab chooses the microphone. It is set to this device's microphone for now,
because the stand-in board has none and plays a stored voice. Switch it to **Clip** once a clip with a
microphone is in use. The Live Call header always names the microphone in use.

The app only shows a clip as connected once the clip has confirmed every step, and names the step if
one fails. If the link drops during a recording made from the clip's audio, the recording is held open
for 30 seconds while the clip reconnects, then ends as "cut short". Bluetooth needs a real iPhone or
iPad; the simulator has none.

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
2. **Mark** drops a numbered mark at that moment. The red button pauses; **Resume recording** carries
   on in the same recording. A recording keeps going when the app is not on screen.
3. **Complete**, and confirm, closes the recording for good. The call moves to the AI Drafts tab under
   **Needs sign-off**, where its handoff and PCR are drafted, and a new call can start straight away.
4. Open a waiting call to fix any line. Yellow lines are ones the AI did not hear.
5. **Sign off** by drawing a signature or typing your name. The call moves to **Signed**.

The AI Drafts tab shows how many calls are waiting for sign-off, and lists every signed call below
them. Home lists three calls: those waiting for sign-off first, then the most recent signed ones. Signed calls open with a tap and delete with a swipe; **Edit**
on one sends it back to be signed again. To throw away the call being recorded, use **Discard call**
on Home.

## Messages you may see

| Message | What it means |
|---|---|
| "No Whisper model is installed" | Run `scripts/fetch_deps.sh`, or copy `ggml-small.en.bin` into the app's Documents folder |
| "N item(s) need you to confirm them" | The two recognisers disagreed, or a value was suggested by the language model. Check the yellow lines |
| "Left out of the narrative because the record does not support them" | The language model wrote a number or drug that was not heard. It was removed |
| "Transcription stopped" | The microphone was taken by a phone call or Siri and could not be taken back. Record again |

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
| `Earshot/ClipLink.swift` | The Bluetooth link to the clip: find, connect, receive (Opus decoded here), send |
| `Earshot/Pipeline/CallEngine.swift` | Transcription: clip or mic audio in, the record and the drafts out. One pipeline session per call |
| `Earshot/Pipeline/NoteWriter.swift`, `AppleNoteWriter.swift` | Optional narrative writer, any model |
| `../core/` | The pipeline (Swift package EarshotCore), shared with the eval tool and its tests |
| `Earshot/Signature.swift` | The sign-off sheet and signature drawing |
| `Earshot/Components.swift` | Colours, fonts, dot-matrix drawing, shared controls |
| `Earshot/Fonts/` | Doto and Geist, both under the Open Font License |

## Not built yet

- **The clip.** It reports no battery level, and the link has no pairing or encryption. Audio spoken
  while the link is down is lost: the clip does not store it.
- **Older systems.** The app also builds for iOS 18 (set `IPHONEOS_DEPLOYMENT_TARGET=18.0`), where
  everything works except the written narrative, which needs Apple Intelligence on iOS 26.
- **Background transcription.** Recording carries on in the background; whether Whisper and the
  live recogniser keep up there has not been confirmed.
- **Not yet built with the pipeline.** The pipeline's app code was written without Xcode and merged
  into the Bluetooth app without a device build. Regenerate the project (`xcodegen`) and build it.
  The pipeline itself is tested (`cd core && swift test`), including against the firmware simulator.
- **Sign-in and audit trail.** Anyone holding the device can open the app and read past calls.
- **Audio.** Only the transcript is kept. No audio file is saved.
- **Long calls.** The on-device model reads about 4,000 tokens. Longer calls fail to draft with a
  message, and the handoff has to be filled in by hand.
- **Languages.** English (US) only.

Calls are stored only on the device, encrypted while it is locked, and kept out of iCloud backups.
Do not record real patients until the privacy and consent questions are settled for your service.
