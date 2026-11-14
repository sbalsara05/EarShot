# Prompt for the app agent: handle the clip's button (single click, double click, hold)

Copy everything below the line into the app development agent.

---

You are working on the Earshot iPad/iPhone app in `app/` (SwiftUI; see `app/README.md`). The
clip firmware (in `firmware/`, version 0.11.0) reports three things the medic does with the
clip's one button. Your job is to make the app act on each of them correctly:

| Gesture on the clip | Message the app receives | What the app must do |
|---|---|---|
| Single click (while recording) | `marker` | Add a mark at that timestamp |
| Double click | `toggle` with `"target":"recording"` | Toggle the **recording**: pause it, or start the next one. The call stays open |
| Press and hold, 1.5 seconds | `toggle` with `"target":"call"` | Toggle the **call**: end the open call, generate its reports and save it; or, if no call is open, open a new one |

The mistake to avoid: a double click must **not** end or start a call. It only pauses and
resumes recording inside the call. Ending a call and starting a new one belong to the hold.

Do not change anything under `firmware/`. If something there looks wrong, say so and stop.

## Where this fits

The clip is a Bluetooth LE peripheral named `ESP-CLIP-XXXX` (the board in hand is
`ESP-CLIP-1814`). `firmware/BLUETOOTH.md` is the full guide to finding it, connecting,
subscribing and staying connected; read it first. In short:

| | ID | Direction | Content |
|---|---|---|---|
| Service | `E5A70001-7C1B-4F0E-9D52-3A6B8C4D2E10` | | Scan for this |
| Audio | `E5A70002-7C1B-4F0E-9D52-3A6B8C4D2E10` | clip → app, notify | One audio packet |
| Events | `E5A70003-7C1B-4F0E-9D52-3A6B8C4D2E10` | clip → app, notify | One UTF-8 JSON object per packet |
| Commands | `E5A70004-7C1B-4F0E-9D52-3A6B8C4D2E10` | app → clip, write | One UTF-8 JSON object per write |

Everything in this task arrives on the events channel and is answered on the commands channel.
Events the app will see, each a complete JSON object in one packet: `hello`, `state`,
`consent`, `marker`, `toggle`. Ignore any `type`, and any `toggle` `target`, you do not know.

An earlier firmware (0.9 and 0.10) sent `{"type":"toggle",...}` with no `target` for a double
click and `{"type":"end",...}` for a hold. If the app handles those, replace that handling with
what is described here: route on `target`.

## The messages

### `marker`: single click while recording

```json
{"type":"marker","id":3,"source":"button","t_ms":61742,"audio_seq":468}
```

- Sent only while the clip is recording. A single click at any other time sends nothing.
- `t_ms` is the clip's own clock (milliseconds since it powered on) **at the click itself**. The
  message arrives about 0.4 seconds later, because the clip waits to see whether a second click
  follows.
- `audio_seq` is the audio packet being captured at the click (packets are 20 ms each and count
  from 0 at the start of each recording).
- `id` counts up by 1 for every mark since the clip powered on. It does not restart per recording.
- `source` is `"button"` for a click on the clip. It is `"tablet"` when the app itself sent
  `{"cmd":"marker"}`, in which case the event is only the clip's echo.
- Marks made while the connection was down are kept and delivered right after the next `hello`,
  with their original `t_ms`.

### `toggle`, target `recording`: double click

```json
{"type":"toggle","target":"recording","source":"button","t_ms":52310}
```

- It is the same message whether or not the clip is recording. Only `t_ms` differs.
- The clip does nothing else. It does not start or stop by itself. It waits for the app.

The app answers on the commands channel with one of:

```json
{"cmd":"start"}
{"cmd":"stop"}
```

The clip then confirms with events, in this order:

```json
{"type":"consent","event":"granted","source":"tablet","t_ms":52390}
{"type":"state","state":"listening","listening":true,"t_ms":52390}
```

or, for a stop:

```json
{"type":"consent","event":"stopped","source":"tablet","t_ms":88120}
{"type":"state","state":"not_listening","listening":false,"t_ms":88120}
```

`start` while already recording, and `stop` while not, do nothing and produce no events.

### `toggle`, target `call`: press and hold

```json
{"type":"toggle","target":"call","source":"button","t_ms":91500}
```

- It is the same message whether or not a call is open and whether or not the clip is
  recording. The app decides what it means.
- If the clip was recording, it has already turned its microphone off by itself, and two events
  arrive just before the toggle:

```json
{"type":"consent","event":"stopped","source":"button","t_ms":91500}
{"type":"state","state":"not_listening","listening":false,"t_ms":91500}
{"type":"toggle","target":"call","source":"button","t_ms":91500}
```

- The app does not send a command in reply.
- The clip's light flashes white once when the hold is taken.

Both toggles are only sent while the app is connected and subscribed. They are never stored and
replayed, so a toggle always means "just now".

## What to build

### 1. Single click: add a mark

On `marker` with `source == "button"`:

- If a recording is in progress, add a mark to it the same way the on-screen Mark button does
  (`Model.mark()` in `app/Earshot/EarshotApp.swift`: it cuts the line being spoken and appends
  `Item(mark: call.markCount + 1)`). Number marks with the app's own count, not the clip's `id`.
- Set the mark's `time` to the moment of the click, not the moment the message arrived. The
  transcript shows that time, and the handoff uses it to find what was said near a mark.
  - Recommended: keep an estimate of the clip's clock against the iPad's. Each time any event
    with `t_ms` arrives, compute `arrival − t_ms`; the smallest value seen on this connection is
    the offset. The click happened at `offset + marker.t_ms`.
  - Acceptable: `arrival − 0.45 s`.
- If no recording is in progress, ignore the mark and log it.
- Remember the last `id` handled on this connection and drop an event whose `id` is not higher.

Ignore `marker` events with `source == "tablet"`. Keep the on-screen Mark button as it is
(local, immediate) and do not send `{"cmd":"marker"}` from it; that way no mark is ever added
twice.

The mark should look and behave exactly like one made on screen: a "Mark N" row in the live
transcript, counted in the recording's summary, and offered a note in the handoff when nothing
was said near it. No new visual is needed.

### 2. Double click: toggle the recording

On `toggle` with `target == "recording"`:

- **A recording is in progress** (`model.live == .listening`): pause it. Send `{"cmd":"stop"}`.
  The call stays open, between recordings, ready to resume. Do not end the call.
- **A call is open but not recording**: begin the next recording in that same call. Send
  `{"cmd":"start"}`. Do not start a new call.
- **No call is open**: there is nothing to record into, so open a call first, as the New call
  button does, and begin its first recording. Send `{"cmd":"start"}`.

Then let the clip's `state` event drive the screen. Treat `state.listening` as the truth about
the microphone: move to the listening screen when `listening: true` arrives and out of it when
`listening: false` arrives. Do not flip the screen on the toggle alone. If no `state` arrives
within 2 seconds of a command, show a problem ("The clip did not answer") and leave things as
they were.

The existing entry points: `Model.record()` starts a recording, `Model.stop(as:)` ends one and
leaves the call open (`.between`), `Model.newCall()` opens a call. Reuse them; do not add a
second path that changes `live`.

Make the on-screen buttons agree with the clip: the app's own Start recording and Stop buttons
must send the same `start` and `stop` commands when a clip is connected, so the clip's light
(red while recording) always matches the app.

### 3. Press and hold: toggle the call

On `toggle` with `target == "call"`:

**If a call is open, end it.** In this order:

1. Stop its recording if one is still running, and close the call so nothing more is added.
2. **Generate the reports**: run what the Analyze button runs (`Model.analyze()`), which drafts
   the nurse handoff and the PCR from the transcript and marks.
3. **Save the call**, with its recordings, transcript, marks and the generated reports, to its
   own file on the device, so it survives the app being closed straight afterwards. The app
   already keeps calls on disk through `Model.save()` and lists finished ones under Past calls;
   build on that. The ended call must appear in Past calls and open from there.
4. Leave no call open, so a new one can be started.

Show the medic the reports for the call that just ended, but do not block: a new call must be
startable from that screen by another hold on the clip, without touching the iPad. If report
generation is still running when the next call starts, let it finish in the background and
save its result into the ended call.

**If no call is open, open a new one**, as the New call button does. It is not recording yet;
a double click starts the recording.

Things to get right:

- **A hold is not a signature.** Save the ended call as ended but unsigned, show that state in
  Past calls, and let the medic open it later to review, edit and sign.
- **Accidental holds.** A 1.5 second hold can happen by accident, for example with the clip
  pressed against a strap. An ended call must be easy to bring back and carry on with: the app
  already has `Model.reopen()` for that.
- **A call with nothing in it.** If the open call has no recordings, just close it; do not
  generate reports or save an empty call.

### 4. Stops the app did not ask for, and reconnects

A `state` with `listening: false` that arrives without your asking (it does just before a call
toggle made while recording) means the clip stopped by itself: end the app's recording, as if
Stop had been tapped. Handle that from `state`, not from the toggle, so it also works when the
toggle never comes.

**A hold made while disconnected.** The microphone still goes off, but no toggle is sent, then
or later. On reconnecting the app gets `hello`, then the stored `consent` `stopped`, then
`state` (`listening: false`). So after every `hello` (it arrives on each connect and reconnect,
followed by `state`), compare the clip's `listening` with the app's:

- Clip not listening, app recording: end the app's recording and leave the call open (paused).
  The call is not ended by this; the medic can hold again once connected, or end it on screen.
- Clip listening, app not recording: send `{"cmd":"stop"}`. The app owns recordings, and it has
  none open.

## Scope

- **In:** the three messages above, sending `start` and `stop`, keeping the app's recording and
  call state in step with the clip, generating reports and saving the call on a call toggle, and
  the mark's placement in time.
- **Out:** decoding the clip's audio. If the app still transcribes from the iPad microphone,
  keep doing that for now, but still send `start` and `stop`, so the clip, its light and the app
  agree. `firmware/BLUETOOTH.md` ("Using the audio") covers feeding clip audio to the
  transcriber when that work is picked up.
- **Out:** the Find clip button (`{"cmd":"find"}`), pairing, and anything in `firmware/`.

## What the clip's light tells you while testing

| Light | Meaning |
|---|---|
| Slow blue blink | No tablet connected; ready for one |
| Green | Connected, not recording |
| Red | Connected, recording |
| Flashing red | Connection lost, or recording with nothing connected |
| One white flash | A mark was made, or a hold was taken |

## Done when

With the clip powered and the app connected (clip light green), and no call open:

1. Hold the clip's button. A new call opens. Nothing is recording; the clip stays green.
2. Double click the clip. A recording starts in that call within about a second and the clip's
   light turns red.
3. Single click the clip. The light flashes white, and a new Mark row appears in the live
   transcript, timed at the click (about half a second before it appeared).
4. Tap the on-screen Mark button. One mark is added, not two.
5. Double click. The recording pauses, the clip turns green, and **the same call is still
   open**.
6. Double click. A second recording starts **in the same call**.
7. Hold. The clip turns green and the recording ends. The call is ended, its reports are
   generated, and it is saved and listed in Past calls as ended but not signed.
8. Without touching the iPad, hold again. A new call opens; the ended call is unchanged.
9. From no call open, double click. A call opens and starts recording in one step.
10. Close the app completely and open it again. The ended call is still in Past calls, with
    its transcript, marks and reports.
11. Open an ended call from Past calls and bring it back to carry on (the accident case).
12. Tap the app's Start recording button. The clip's light turns red. Tap Stop: green.
13. Double click, and hold, with the app closed or out of range, then reconnect. Nothing
    starts and no call is ended or opened; a recording that was running shows as paused.

Also cover the message handling with unit tests, using the JSON samples above as input,
including a `toggle` for each target in each app state.

Report back with what you changed, which of the thirteen checks you ran on real hardware, and
anything in the firmware's behaviour that did not match this description.
