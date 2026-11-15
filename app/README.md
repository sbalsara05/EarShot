# Earshot app

The iPhone and iPad app. It records a call, shows a live transcript with marks, and lays the call out as
a NEMSIS report for the medic to check, correct and sign.

Before the first build, run `../transcribe/fetch.sh` and `../fill/fetch.sh` once each. The first builds whisper.cpp
and pulls the Whisper model from Git LFS; Whisper writes the transcript (see [`transcribe/README.md`](../transcribe/README.md)).
The second builds llama.cpp and downloads the 2.7 GB language model that fills the report from the transcript
(see [`fill/README.md`](../fill/README.md)). Without the second the app still builds, and reports are filled by hand.

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

The Clip tab and the Live Call screen show this as a **Clip button** key: one dot for a click, two for a
double click, a bar for a hold. On Live Call it says what each does at that point in the call and dims the
ones that do nothing.

**Audio from** in Settings (the gear beside the tabs) chooses the microphone. It is set to this device's microphone for now,
because the stand-in board has none and plays a stored voice. Switch it to **Clip** once a clip with a
microphone is in use. The Live Call header always names the microphone in use.

Settings also holds the values that are the same on every call: agency, unit, crew and usual area. Each is
labelled with the NEMSIS 3.5.0 box it fills, and the choices use NEMSIS's own code lists. They are typed once
and kept on the device. Nothing reads them yet: they are there for the NEMSIS report.

**Location.** The app asks to use location when it is first opened, then asks to change that to Always, so
places are still logged with the app off screen or the device locked. During a recording it checks the
device's place once a minute and adds a location row to the transcript when it has moved 50 metres or more,
so a call at one address logs it once. The row carries the address when one can be looked up (that needs a
network) and the coordinates either way. Settings shows whether location is allowed.

**Call audio.** The audio is saved as it arrives, one small `.opus` file for each unbroken stretch (Start or
Resume to Pause). The clip's Opus packets are written as they came, with nothing re-encoded; the microphone's
audio is encoded to Opus first. A line's time in the transcript is its place in the file, so on a completed
call a tap on a line plays it back. Files are in `Application Support/audio/<call id>/`.

**Transcript.** Two recognisers hear the same audio. This device's own shows words at once. Whisper reads the
audio again a pause at a time, and its line takes the place of the live words a few seconds later. Each of
Whisper's lines carries a confidence from 0 to 1 and a time for every word. A line the live recogniser heard
and Whisper wrote nothing for is kept, marked as such, with a confidence of 0. Lighter lines in a transcript are
the ones to read with care: those, and Whisper's lines under 0.6. Settings names the model in use, and the branch
and commit the build came from. Where a device cannot recognise speech itself, recording still works and text
arrives a pause at a time. Without the Whisper model the app uses live words only, as before.

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

## Run it in the simulator

1. Open `Earshot.xcodeproj` in Xcode.
2. Pick an iPhone or iPad simulator and press Run.

The simulator is good for checking screens and the flow. Two things do not work there:

- **Recording.** The simulator has no speech model, so a recording stops straight away with
  "Failed to initialize recognizer". That is expected.

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
3. **Complete**, and confirm, closes the recording for good. The call moves to the Reports tab under
   **Needs sign-off**, and a new call can start straight away.
4. When the transcript is finished the report is filled from it, on the device: a minute or two, shown as
   "Filling report". Then open the call. **Summary** is its NEMSIS report: a card for each section (Times, Patient,
   Scene, Situation, History, Vitals, Medications, Procedures, Disposition, Narrative), with a card for each set
   of vitals, each medication and each procedure. An answer the transcript gave carries a small time chip: tap it
   to see the line it came from and hear it. Yellow answers are the ones to look at. Anything can be typed over,
   and what could not be found reads n/a. **Fill again** reads the transcript again; answers you typed stay.
5. **Transcript** is what was said. Tap a line to hear it again. A mark dropped by accident (a stray click
   on the clip) can be deleted here: swipe it left and tap **Delete**. The marks after it move up a number.
6. **Sign off** by drawing a signature or typing your name. The call moves to **Signed**.
7. On a signed call, **Export XML** shares the report as a NEMSIS 3.5.1 file.

The Reports tab shows how many calls are waiting for sign-off, and lists every signed call below
them. Home lists three calls: those waiting for sign-off first, then the most recent signed ones. Signed calls open with a tap and delete with a swipe; **Edit**
on one sends it back to be signed again. To throw away the call being recorded, use **Discard call**
on Home.

## Messages you may see

| Message | What it means |
|---|---|
| "This iPhone cannot transcribe English on the device yet" | The device has no on-device speech model, so the app will not record. It never sends call audio to a server |
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
| `Earshot/CallScreens.swift` | Live Call, Reports, and the past-call screen |
| `Earshot/Recorder.swift` | Audio to live words (microphone or clip) |
| `Earshot/Nemsis.swift` | The Summary screen: the NEMSIS report as cards |
| `Earshot/Report.swift` | Filling a call's report from its transcript, and exporting it as XML (the work is in `fill/`) |
| `Earshot/Record.swift` | Whisper's side of a call: the same audio, read into the lines that replace the live words |
| `Earshot/Tape.swift` | A call's audio on disk: saving it as it arrives, reading a part back, playing a line |
| `Earshot/OggOpus.swift` | The .opus file format the audio is saved in |
| `Earshot/ClipLink.swift` | The Bluetooth link to the clip: find, connect, receive, send |
| `Earshot/Settings.swift` | Settings: the audio source, and the values stamped on every report |
| `Earshot/Location.swift` | The once-a-minute place check during a recording |
| `Earshot/Signature.swift` | The sign-off sheet and signature drawing |
| `Earshot/Components.swift` | Colours, fonts, dot-matrix drawing, shared controls |
| `Earshot/Fonts/` | Doto and Geist, both under the Open Font License |

## Not built yet

- **The clip.** It reports no battery level, and the link has no pairing or encryption. Audio spoken
  while the link is down is lost: the clip does not store it.
- **Older systems.** The app also builds for iOS 18 (set `IPHONEOS_DEPLOYMENT_TARGET=18.0`).
- **Background transcription.** Recording carries on in the background; whether on-device
  transcription keeps up there has not been confirmed.
- **Sign-in and audit trail.** Anyone holding the device can open the app and read past calls.
- **Audio.** Each call's audio is kept on the device beside its transcript, about 15 MB an hour from the clip
  and 8 MB from the microphone, and is deleted with the call. It is never sent anywhere. Nothing reads it again
  yet: it is there to be heard, and for a later step to re-read a line it doubts.
- **The report.** Filled from the transcript, but only what was plainly said and can be traced to a line; the
  rest is for the medic. The XML passes the NEMSIS schema; fields NEMSIS wants as codes (impression, procedure,
  allergies) go out as "not recorded". See [`fill/README.md`](../fill/README.md) for what was measured and what was not.
  The fill has been run on a Mac and in the simulator's screens, not yet timed on an iPad.
- **Languages.** English (US) only.

Calls are stored only on the device, encrypted while it is locked, and kept out of iCloud backups.
Do not record real patients until the privacy and consent questions are settled for your service.
