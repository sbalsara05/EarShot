# Prompt for the app agent: handle the clip's button (double click, single click, hold)

Copy everything below the line into the app development agent.

---

You are working on the Earshot iPad/iPhone app in `app/` (SwiftUI; see `app/README.md`). The
clip firmware (in `firmware/`, version 0.10.0) now reports three things the medic does with the
clip's one button. Your job is to make the app act on them:

1. **Double click → `toggle`: pause or resume.** The clip asks; the app decides whether to
   pause the recording in progress or begin the next one, and tells the clip.
2. **Single click while recording → `marker`.** The app adds a mark to the live transcript at
   the moment of the click.
3. **Hold for 1.5 seconds → `end`: end the call.** The clip turns its microphone off by itself;
   the app closes the call.

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

If the app does not yet connect to the clip and receive the events channel, build that first,
following `firmware/BLUETOOTH.md`. Everything in this task arrives on the events channel and is
answered on the commands channel. Decoding the audio channel is a separate task; see
"Scope" below.

Events the app will see, each a complete JSON object in one packet: `hello`, `state`,
`consent`, `marker`, `toggle`, `end`. Ignore any `type` you do not know.

## The three messages

### `toggle`: the medic double-clicked (pause or resume)

```json
{"type":"toggle","source":"button","t_ms":52310}
```

- It is **the same message whether or not the clip is recording**. Only `t_ms` differs.
- The clip does nothing else. It does not start or stop by itself. It waits for the app.
- `t_ms` is the clip's own clock (milliseconds since it powered on) when the button went down.
- It is only sent while the app is connected and subscribed. It is never stored and replayed, so
  a toggle always means "just now".

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

### `end`: the medic held the button for 1.5 seconds (end the call)

If the clip was recording, three events arrive together, in this order:

```json
{"type":"consent","event":"stopped","source":"button","t_ms":91500}
{"type":"state","state":"not_listening","listening":false,"t_ms":91500}
{"type":"end","source":"button","t_ms":91500}
```

If it was not recording (the call was paused), `end` arrives alone:

```json
{"type":"end","source":"button","t_ms":91500}
```

- The clip has already turned its microphone off. The app does not send a command in reply.
- Like `toggle`, it is only sent while the app is connected and is never stored and replayed.
- The clip's light flashes white once when the hold is taken.

### `marker`: the medic single-clicked while recording

```json
{"type":"marker","id":3,"source":"button","t_ms":61742,"audio_seq":468}
```

- Sent only while the clip is recording. A single click at any other time sends nothing.
- `t_ms` is the clip's clock **at the click itself**. The message arrives about 0.4 seconds
  later, because the clip has to wait to see whether a second click follows.
- `audio_seq` is the audio packet being captured at the click (packets are 20 ms each and count
  from 0 at the start of each recording).
- `id` counts up by 1 for every mark since the clip powered on. It does not restart per recording.
- `source` is `"button"` for a click on the clip. It is `"tablet"` when the app itself sent
  `{"cmd":"marker"}`, in which case the event is only the clip's echo.
- Marks made while the connection was down are kept and delivered right after the next `hello`,
  with their original `t_ms`.

## What to build

### 1. Double click: pause or resume

On `toggle`:

- **A recording is in progress** (`model.live == .listening`): pause it. Send `{"cmd":"stop"}`.
  The call stays open, between recordings, ready to resume.
- **Otherwise**: begin the next recording in the call. If no call is open
  (`model.live == .none`), open one first, as the New call button does. Send `{"cmd":"start"}`.

Then let the clip's `state` event drive the screen. Treat `state.listening` as the truth about
the microphone: move to the listening screen when `listening: true` arrives and out of it when
`listening: false` arrives. Do not flip the screen on the toggle alone. If no `state` arrives
within 2 seconds of a command, show a problem ("The clip did not answer") and leave things as
they were.

The existing entry points are in `app/Earshot/EarshotApp.swift`: `Model.record()` starts a
recording, `Model.stop(as:)` ends one and leaves the call open (`.between`), `Model.newCall()`
opens a call. Reuse them; do not add a second path that changes `live`.

Make the on-screen buttons agree with the clip: the app's own Start recording and Stop buttons
must send the same `start` and `stop` commands when a clip is connected, so the clip's light
(red while recording) always matches the app.

### 2. Hold: end the call

On `end`:

- If a call is open, end its recording if one is still running, then take the medic to the
  drafts, as the Analyze button does (`Model.analyze()`).
- **Do not sign the call off.** A 1.5 second hold can happen by accident, for example with the
  clip pressed against a strap. Landing on the drafts is easy to back out of; a signature is not.
- If no call is open, or the open call has no recordings, ignore it and log it.

A `state` with `listening: false` that arrives without your asking (it does just before `end`)
means the clip stopped by itself: end the app's recording, as if Stop had been tapped. Handle
that from `state`, not from `end`, so it also works when `end` never comes (see the next point).

**A hold made while disconnected.** The microphone still goes off, but no `end` is sent, then
or later. On reconnecting the app gets `hello`, then the stored `consent` `stopped`, then
`state` (`listening: false`). So after every `hello` (it arrives on each connect and reconnect,
followed by `state`), compare the clip's `listening` with the app's:

- Clip not listening, app recording: end the app's recording and leave the call open (paused).
  The medic stopped it on the clip while out of range; they can end the call on screen.
- Clip listening, app not recording: send `{"cmd":"stop"}`. The app owns recordings, and it has
  none open.

### 3. Single click: add a mark

On `marker` with `source == "button"`:

- If a recording is in progress, add a mark to it the same way the on-screen Mark button does
  (`Model.mark()`: it cuts the line being spoken and appends `Item(mark: call.markCount + 1)`).
  Number marks with the app's own count, not the clip's `id`.
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

## Scope

- **In:** receiving `toggle`, `marker` and `end`, sending `start` and `stop`, keeping the app's
  recording state in step with the clip, and the mark's placement in time.
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

With the clip powered and the app connected (clip light green):

1. Double click the clip. The app starts a recording within about a second and the clip's
   light turns red.
2. Single click the clip. The light flashes white, and a new Mark row appears in the live
   transcript, timed at the click (about half a second before it appeared).
3. Tap the on-screen Mark button. One mark is added, not two.
4. Double click the clip again. The app pauses: the recording ends, the call stays open, and
   the clip's light turns green.
5. Double click once more. A second recording starts in the same call.
6. Hold the clip's button for 1.5 seconds. The clip's light goes green, the recording ends, and
   the app shows the drafts for that call. The call is not signed.
7. With a call open but paused, hold the button. The app shows the drafts.
8. Tap the app's Start recording button. The clip's light turns red. Tap Stop: green.
9. Double click, and hold, with the app closed or out of range, then reconnect. Nothing starts
   and no call is ended; a recording that was running shows as paused.

Also cover the message handling with unit tests, using the JSON samples above as input.

Report back with what you changed, which of the nine checks you ran on real hardware, and
anything in the firmware's behaviour that did not match this description.
