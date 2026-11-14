# Bluetooth link: what the app needs to know

How the iPad app finds the clip, connects to it, receives audio, and stays connected. The
firmware side of this is built (firmware 0.6.0, `src/ble_link.cpp`). The app side is not.

Status: tried once over the air, on 13 Nov 2026, between an ESP32-S3 Feather and a Mac running
`tools/ble_receiver.py`: 652 of 652 audio packets arrived, none lost, and the decoded audio
transcribed word for word. It has not been tried with iOS or an iPad yet.

## Who does what

The clip advertises. The app scans, connects and subscribes. Then the clip pushes packets.

| Step | Who | What happens |
|---|---|---|
| 1 | Clip | From power-on it broadcasts its service ID and its name (`ESP-CLIP-` plus four hex digits, for example `ESP-CLIP-A3F2`) about eight times a second. Its light blinks blue slowly while it waits |
| 2 | App | Scans for the service ID, sees the clip, connects |
| 3 | App | Looks up the service and its three channels |
| 4 | App | Subscribes to the audio channel, then the events channel |
| 5 | Clip | Sends `hello` and `state` as soon as the events channel is subscribed, then events and audio as they happen. Its light turns solid green (red while it is listening) |

In Bluetooth terms the clip is the peripheral and the app is the central. A "channel" is a
characteristic; "subscribing" is turning on notifications.

## IDs

| | ID | Direction | Content |
|---|---|---|---|
| Service | `E5A70001-7C1B-4F0E-9D52-3A6B8C4D2E10` | | Scan for this |
| Audio | `E5A70002-7C1B-4F0E-9D52-3A6B8C4D2E10` | clip to app, notify | One audio frame per packet |
| Events | `E5A70003-7C1B-4F0E-9D52-3A6B8C4D2E10` | clip to app, notify | One JSON message per packet |
| Commands | `E5A70004-7C1B-4F0E-9D52-3A6B8C4D2E10` | app to clip, write | One JSON command per write |

## Packets

Every message is one packet of at most 160 bytes. iOS allows 182, so nothing is ever split and
the app never has to join packets together.

**Audio packet** (88 bytes; 50 per second while listening, about 4,400 bytes per second):

| Bytes | Type | Meaning |
|---|---|---|
| 0 to 3 | uint32, little-endian | `seq`: frame counter. Restarts at 0 with every capture. A gap means frames were lost |
| 4 to 7 | uint32, little-endian | `t_ms`: the clip's clock in milliseconds when the frame was captured |
| 8 to 87 | bytes | One Opus packet: 20 ms of 16 kHz mono speech at 32 kbit/s, constant bitrate |

**Events** (UTF-8 JSON, clip to app):

```json
{"type":"hello","device":"ESP-CLIP-A3F2","fw":"0.11.0","audio":{"codec":"opus","rate":16000,"channels":1,"frame_ms":20,"bitrate":32000}}
{"type":"state","state":"listening","listening":true,"t_ms":41234}
{"type":"consent","event":"granted","source":"button","t_ms":41230}
{"type":"consent","event":"stopped","source":"tablet","t_ms":63010}
{"type":"marker","id":1,"source":"button","t_ms":47781,"audio_seq":327}
{"type":"toggle","target":"recording","source":"button","t_ms":52310}
{"type":"toggle","target":"call","source":"button","t_ms":91500}
```

- **`toggle` with target `recording` is a double click: toggle the recording.** It is the same
  message whether or not the clip is recording, and the clip does nothing else: the app decides.
  Answer `{"cmd":"stop"}` to pause a recording in progress, or `{"cmd":"start"}` to begin the
  next one. The call stays open either way.
- **`toggle` with target `call` is a 1.5 second hold: toggle the call.** End the open call,
  generate its reports and save it; or open a new call if none is open. If the clip was
  recording it has already stopped by itself, and a `consent` `stopped` and a `state` arrive
  just before the toggle.
- Toggles are only sent while the app is connected, and are never replayed after a reconnect.
  `firmware/APP_AGENT_PROMPT.md` spells out what the app should do on each.
- **`marker` is a mark** (a single click while recording, or the app's own `marker` command).
  `t_ms` and `audio_seq` are those of the click itself; `audio_seq` is the audio packet being
  captured at that moment. `id` counts up from 1 since the clip was powered on.
- `consent` `granted` arrives before the first audio packet of a capture; `stopped` after the last.
- `source` says whether the clip's button or the app caused it.
- `t_ms` counts from when the clip powered on. Stamp the real time when the message arrives.

**Commands** (UTF-8 JSON, app to clip):

```json
{"cmd":"start"}
{"cmd":"stop"}
{"cmd":"marker"}
{"cmd":"find"}
```

`start` begins a capture and `stop` ends one; these are how the app answers a `toggle`. The
clip replies with `consent` and `state` events. Either write type works.

`find` is for the Clip tab's **Find clip** button. The clip blinks its light white and beeps for
3.2 seconds, the same time the button shows "Blinking and buzzing", then stops by itself.
Sending it again restarts the timer. It never starts or stops a capture. While the clip is
listening it only blinks, so the beep cannot end up in a recording. There is no reply message.

## App checklist

1. **Permission.** Add `NSBluetoothAlwaysUsageDescription` to `Info.plist`. Without it the app
   crashes the first time it touches Bluetooth.
2. **Background.** Add `bluetooth-central` to `UIBackgroundModes`, so packets keep arriving when
   the iPad's screen locks.
3. **Scan.** Create a `CBCentralManager`, wait for `.poweredOn`, then
   `scanForPeripherals(withServices: [serviceID])`.
4. **Connect.** In `didDiscover`, stop scanning, **store the `CBPeripheral` in a property**, set
   its delegate and call `connect`. If nothing holds the peripheral, iOS drops the connection
   without an error.
5. **Channels.** `discoverServices([serviceID])`, then `discoverCharacteristics`, then
   `setNotifyValue(true, for:)` on audio and on events. Subscribe to audio first: the clip
   starts talking the moment events is subscribed.
6. **Receive.** `didUpdateValueFor` delivers one packet per call. Route by characteristic ID.
7. **Send.** `writeValue(_:for:type:)` on the commands characteristic.

The simulator in Xcode has no Bluetooth. This needs a real iPad or iPhone.

## Staying connected

The clip does its half: it starts advertising again the instant a connection drops, and it says
`hello` again on every new subscription. The app's half:

- **A Disconnect button should call `cancelPeripheralConnection`.** The clip sees that as a
  deliberate goodbye and goes back to its slow blue "ready to connect" blink. If the iPad
  just goes out of range, the clip flashes red until it is back. Do not reconnect
  automatically after a disconnect the user asked for.
- **On an unexpected disconnect, reconnect at once.** In `didDisconnectPeripheral`, call `connect` on the same
  peripheral. That request does not time out, so the link returns by itself when the clip is
  back in range or powered again.
- **Subscribe again after every connect.** Nothing carries over from the last connection. In
  `didConnect`, repeat step 5: look up the service and channels and turn notifications back on.
- **Remember the clip.** Save `peripheral.identifier`. On launch, get it back with
  `retrievePeripherals(withIdentifiers:)` and connect without scanning.
- **Treat `hello` as "start of a connection".** It arrives after every connect, including
  reconnects. `state` follows it and says whether a capture is in progress.
- **Expect a gap in `seq` after a reconnect.** While disconnected the clip keeps listening and
  drops the audio; it does not store it. Events (consent, markers) from that time are kept and
  delivered right after `hello`.

## Using the audio

Each audio packet holds one Opus frame. Decode it to 16 kHz mono PCM and hand it to the
recogniser where the microphone audio goes today: `Transcriber` in `app/Earshot/Recorder.swift`
appends `AVAudioPCMBuffer`s to its `SFSpeechAudioBufferRecognitionRequest` in the mic tap, and
clip audio can be appended the same way.

For decoding, iOS has an Opus decoder in AudioToolbox (`kAudioFormatOpus`, through
`AVAudioConverter`), and libopus is available as Swift packages. Neither has been tried here.
`tools/ble_receiver.py` shows the decode step with libopus in about ten lines.

## Testing without the app

- **On a phone:** install nRF Connect or LightBlue. Scan, connect to `ESP-CLIP-XXXX`, turn on
  notifications for the two notify characteristics, then double-click the clip's button: a
  `toggle` event shows as text. Write `{"cmd":"start"}` to the commands characteristic and audio
  arrives as 88-byte packets.
- **On a Mac:** `tools/ble_receiver.py` does all five steps, decodes the audio to a WAV file,
  reconnects on its own and can transcribe what it received. See the top of that file.

On the Feather stand-in board the "microphone" is a 12.9 second recording that loops:

> Sixty eight year old male with chest pain for thirty minutes, radiating to the left arm.
> Blood pressure is one fifty over ninety. Heart rate is one hundred and four. Aspirin given at
> fourteen ten.

So a correct app shows that text. The same chain on the laptop (simulated clip, Opus, mock
tablet, Whisper) gives it back word for word (`tools/check_voice_clip.py`).

## Limits

- **No pairing or encryption.** Anyone nearby with the right tool could connect and receive the
  audio. Fine for a demo with a recorded voice; the real product needs bonding with encryption.
- **One tablet at a time.** While connected the clip does not advertise.
- **Timing is up to iOS.** The clip asks for a 15 to 30 ms connection interval; iOS decides. The
  firmware's status line prints what it got.
- **Raw audio cannot be sent.** A raw frame is 640 bytes; only Opus fits a packet.
