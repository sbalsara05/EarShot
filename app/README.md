# Earshot app

The iPhone and iPad app. It records a call, shows a live transcript with marks, then drafts a nurse
handoff and a PCR for the medic to edit and sign.

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
| For live transcription | A real iPhone or iPad. It does not work in the simulator |
| For AI drafts | Apple Intelligence turned on (iPhone 15 Pro or later, or an iPad with an M1 or A17 Pro chip or later) |

## Run it in the simulator

1. Open `Earshot.xcodeproj` in Xcode.
2. Pick an iPhone or iPad simulator and press Run.

The simulator is good for checking screens and the flow. Two things do not work there:

- **Recording.** The simulator has no speech model, so a recording stops straight away with
  "Failed to initialize recognizer". That is expected.
- **Drafts.** They only run if Apple Intelligence is turned on in the Mac's System Settings. Without
  it, the handoff opens blank with a yellow note.

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
5. Choose the **Narrative format** under PCR: Plain, SOAP, CHART or DRAATT. The narrative is rewritten in
   that format from the transcript, on the device, in a few seconds; the rest of the report does not change.
   Going back to a format already written for the call is instant and brings back the same words. The
   format you choose is used for the first draft of your next calls. A section the call said nothing
   about reads "Not heard."
6. **Sign off** by drawing a signature or typing your name. The call moves to **Signed**, with its
   narrative in the format it was signed in. **Copy PCR** copies it that way too.

The AI Drafts tab shows how many calls are waiting for sign-off, and lists every signed call below
them. Home lists three calls: those waiting for sign-off first, then the most recent signed ones. Signed calls open with a tap and delete with a swipe; **Edit**
on one sends it back to be signed again. To throw away the call being recorded, use **Discard call**
on Home.

## Messages you may see

| Message | What it means |
|---|---|
| "This iPhone cannot transcribe English on the device yet" | The device has no on-device speech model, so the app will not record. It never sends call audio to a server |
| "Nothing was drafted. Apple Intelligence is turned off" | Turn Apple Intelligence on in Settings. A completed call is not drafted again, so fill its lines in by hand |
| "The on-device model is still downloading" | Apple Intelligence was just turned on. Wait a few minutes |
| "Transcription stopped" | The recogniser failed. In the simulator this is expected |

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
| `Earshot/Recorder.swift` | Audio to text (microphone or clip), and transcript to drafts |
| `Earshot/ClipLink.swift` | The Bluetooth link to the clip: find, connect, receive, send |
| `Earshot/Signature.swift` | The sign-off sheet and signature drawing |
| `Earshot/Components.swift` | Colours, fonts, dot-matrix drawing, shared controls |
| `Earshot/Fonts/` | Doto and Geist, both under the Open Font License |

## Not built yet

- **The clip.** It reports no battery level, and the link has no pairing or encryption. Audio spoken
  while the link is down is lost: the clip does not store it.
- **Older systems.** The app also builds for iOS 18 (set `IPHONEOS_DEPLOYMENT_TARGET=18.0`), where
  everything works except the AI drafts, which need iOS 26.
- **Background transcription.** Recording carries on in the background; whether on-device
  transcription keeps up there has not been confirmed.
- **Sign-in and audit trail.** Anyone holding the device can open the app and read past calls.
- **Audio.** Only the transcript is kept. No audio file is saved.
- **Long calls.** The on-device model reads about 4,000 tokens. Longer calls fail to draft with a
  message, and the handoff has to be filled in by hand.
- **Languages.** English (US) only.

Calls are stored only on the device, encrypted while it is locked, and kept out of iCloud backups.
Do not record real patients until the privacy and consent questions are settled for your service.
