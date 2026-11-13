# Earshot clip firmware

Firmware for the Earshot clip (M5Stack Atom VoiceS3R), plus a laptop simulator so it can be
tested without the hardware.

## What the clip does

The consent flow follows the PRD: press to ask consent, hold to stop.

| Ring | State | What is happening |
|---|---|---|
| Dark | Not listening | Mic off. Nothing is captured |
| Amber | Asking | The medic is asking the patient. Mic still off |
| Green | Listening | Consent logged. Mic on, audio streams to the tablet |
| White flash | | Marker dropped |
| Blinking | | Asking or listening, but not connected to the tablet |

| Gesture | When | Effect |
|---|---|---|
| Press | Not listening | Start the consent ask (amber) |
| Press | Asking | The patient said yes: consent logged, capture starts (green) |
| Hold 1.5 s | Asking | The patient said no: refusal logged, back to not listening |
| Hold 1.5 s | Listening | Stop the capture |
| Double tap | Listening | Timestamp marker sent to the tablet |

The tablet can drive the same flow with commands (`ask`, `consent_grant`, `consent_decline`,
`stop`, `marker`), so the PCR app can start and stop a recording.

Details worth knowing:

- The microphone is only on while the ring is green. Nothing is captured before consent, so there is nothing to wipe or withhold.
- The consent message is sent before the first audio frame, and every ask, yes, no and stop is logged with a timestamp.
- A press while already listening is ignored, so a bumped button cannot cut the capture. A double tap is never taken as a "yes".
- Each capture restarts the audio frame counter at 0, which gives the tablet a clean boundary between patients.
- If the link drops while listening, audio is dropped (not stored); consent events and markers are queued and sent on reconnect.
- The board has no battery or power switch: plugging in USB powers it, and it starts in "not listening".

## Layout

| Path | What |
|---|---|
| `lib/earshot_core/` | All behaviour: button gestures, consent state machine, WebSocket client, streaming. Portable C++11, no Arduino code |
| `src/main.cpp` | Atom VoiceS3R hardware layer: button pin, LED ring, mic, Wi-Fi |
| `include/config.example.h` | Wi-Fi, gateway address, pins |
| `host_tests/` | Unit tests for the core, run on the laptop |
| `sim/sim_clip.cpp` | Simulated clip: the same core with a keyboard/UI button, generated audio and a real socket |
| `sim/tablet.py`, `sim/index.html` | Mock tablet and browser UI |
| `sim/e2e_test.py` | Scripted end-to-end check |
| `sim/record_demo.py` | Records a scripted simulator run into `evidence/` |
| `sim/make_wokwi_web.py` | Packages the firmware for the Wokwi website |
| `wokwi.toml`, `diagram.json` | Wokwi virtual board setup |

## Simulator

Needs a C++ compiler, Python 3 and `pip install websockets`.

```bash
make test
```

```bash
make e2e
```

```bash
make run
```

`make run` serves the UI at http://localhost:8765. The left panel is the clip: click to press,
hold for a long press, double-click for a marker (the space bar works too). The right panel is
the mock tablet and shows exactly what arrived, including an "audio without consent" counter
that must stay at 0 and a count of refusals logged.

### Testing with a microphone

By default the simulated clip hears a test tone. Under **Clip microphone**, choose **Laptop mic**
and allow microphone access: the laptop's microphone then stands in for the clip's microphone.
Open the page in Chrome or Safari for this (http://localhost:8765).

- Speak while the ring is dark or amber: the tablet stays at 0 bytes.
- Get the ring to green, speak, stop, then press **Play received audio** to hear exactly what the tablet was sent.

The laptop mic tests the whole path with real speech. It does not tell you how the clip's own
microphone sounds; for that, run the real device against `sim/tablet.py --no-sim --lan` and use
the same **Play received audio** button.

You can also feed a recording: `python3 sim/tablet.py --wav call.wav` (16 kHz mono 16-bit WAV).

### Recording a run as evidence

```bash
python3 sim/record_demo.py
```

This runs a scripted scenario in headless Chrome with real press and hold timings and writes
`evidence/<date>-sim-run/`: a captioned real-time `recording.mp4`, one still per step, and
`messages.jsonl` (every clip/tablet message plus the tablet's ledger each second). It needs
Google Chrome and `pip install pillow`; the video is encoded with macOS's built-in encoder
(elsewhere it falls back to a GIF). Videos in `evidence/` are git-ignored: they are for viewing
locally, while the stills, logs and notes can be committed. For a log of a manual session instead, start the tablet
with `--event-log FILE`.

What the simulator does not cover: the clip's real microphone and codec, the LED ring hardware,
and Wi-Fi behaviour. Those need the device.

## Wokwi (virtual ESP32-S3)

The local simulator runs the firmware's logic compiled for the laptop. Wokwi complements it by
running the actual ESP32 program on a virtual chip, so it exercises the hardware layer in
`src/main.cpp`: the button pin with simulated contact bounce, the LED ring driver, the Wi-Fi
connection and the link to the tablet.

Wokwi cannot simulate the microphone bus (I2S) or Bluetooth on the ESP32-S3, so the `wokwi`
build replaces the mic with a 440 Hz tone. Microphone testing stays with the local simulator
(laptop mic) and the real device.

1. In VS Code, install the **Wokwi Simulator** extension, then F1 → "Wokwi: Request a new License" (free account).
2. Build the Wokwi firmware: `pio run -e wokwi`
3. Start the mock tablet: `python3 sim/tablet.py --no-sim`
4. Open the `firmware/` folder in VS Code, then F1 → "Wokwi: Start Simulator".

Click the blue button (or hold the **B** key) for the clip button. The ring goes amber on the
first press and green on the second; http://localhost:8765 shows what the virtual clip sent. The
virtual board reaches the laptop as `host.wokwi.internal` through the gateway built into the
extension.

`wokwi.toml` and `diagram.json` hold the setup: button on G41, a 12-pixel ring on G2.

### On the Wokwi website (no install)

```bash
python3 sim/make_wokwi_web.py
```

This writes `build/wokwi_web/`: a tiny `sketch.ino`, the whole firmware folded into `earshot.h`,
`diagram.json` and `libraries.txt`. Open https://wokwi.com/projects/new/esp32-s3, paste
`sketch.ino` and `diagram.json` into their tabs, add a file named `earshot.h` (arrow next to
"Library Manager" → New file) and paste it in, add **Adafruit NeoPixel** in the Library Manager,
then press play. No account is needed to run it.

The website cannot reach a tablet on your laptop, so this build is standalone: the ring shows
the consent state (dark, amber, green) and the serial monitor prints the clip's state every
5 seconds, but nothing is streamed. A recorded run is in `evidence/2026-11-13-wokwi-run/`.

## Real device

1. Install PlatformIO (`pip install platformio`, or the VS Code extension).
2. `cp include/config.example.h include/config.h` and fill in Wi-Fi and the laptop's IP.
3. Start the mock tablet so a clip on the Wi-Fi can reach it: `python3 sim/tablet.py --no-sim --lan`
4. Put the clip in download mode if needed (hold the reset button about 2 s until the internal green LED lights, then release), then `pio run -t upload`.
5. `pio device monitor` prints a status line every 5 seconds.

Add `--save-wav` to the tablet command to write received audio to `sim/out/` and listen to it.
That flag is a test aid only.

Hardware notes for the Atom VoiceS3R:

- Button is G41. The mic goes through the ES8311 codec, driven by M5Unified.
- The board has no RGB LED. The consent ring is an external WS2812 ring on the Grove port (data on G2, yellow wire). Set `LED_COUNT` in `config.h`.
- Wi-Fi is 2.4 GHz only.

## Protocol

WebSocket, clip connects to `ws://<gateway>:8765/clip`. Full definition is in
[`lib/earshot_core/src/protocol.h`](lib/earshot_core/src/protocol.h).

- **Events** (text, JSON): `hello`, `state` (`not_listening`, `asking`, `listening`), `consent` (`asked`, `granted`, `declined`, `stopped`), `marker`.
- **Audio** (binary, only between `granted` and `declined`/`stopped`): 8-byte header (`uint32 seq`, `uint32 t_ms`, little-endian) followed by 640 bytes of 16 kHz mono 16-bit PCM (20 ms).
- **Commands** (text, JSON, tablet to clip): `{"cmd":"ask"}`, `consent_grant`, `consent_decline`, `stop`, `marker`.

`t_ms` is milliseconds since the clip booted. The tablet should stamp wall-clock time on receipt.
`sim/tablet.py` is a working reference for the tablet side.

## Porting to another ESP32 board

Only `src/main.cpp` changes: swap the mic code for the new board's I2S microphone and adjust the
pins in `config.h`. The core, tests and simulator stay as they are.
