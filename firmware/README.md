# Earshot clip firmware

Firmware for the Earshot clip (M5Stack Atom VoiceS3R), plus a laptop simulator so it can be
tested without the hardware. It also builds for an Adafruit ESP32-S3 Feather, as a stand-in
board until the Atom arrives.

The clip sends to the tablet over Bluetooth LE. [BLUETOOTH.md](BLUETOOTH.md) is the app-side
guide: how to find the clip, connect, read the packets and stay connected.

Run on hardware once so far (13 Nov 2026): flashed to the Feather and received on a Mac over
Bluetooth with no audio packets lost. Not yet tried: the Atom VoiceS3R, an iPad, and the
physical button and light.

## What the clip does

Press to start, hold to stop.

| Ring | State | What is happening |
|---|---|---|
| Dark | Not listening | Mic off. Nothing is captured |
| Green | Listening | Mic on, audio streams to the tablet |
| White flash | | Marker dropped |
| Blinking | | Listening, but not connected to the tablet |

| Gesture | When | Effect |
|---|---|---|
| Press | Not listening | Start: consent is logged and capture begins (green) |
| Hold 1.5 s | Listening | Stop the capture |
| Double tap | Listening | Timestamp marker sent to the tablet |

The medic asks the patient for consent out loud, as they already do. Pressing the button is the
medic's confirmation that the patient agreed: the clip logs it as a consent event and only then
starts the microphone. If the patient says no, the medic does not press.

The tablet can drive the same flow with commands (`start`, `stop`, `marker`), so the PCR app can
start and stop a recording.

Details worth knowing:

- The microphone is only on while the ring is green. Nothing is captured before the press, so there is nothing to wipe or withhold.
- The consent message is sent before the first audio frame, and every start and stop is logged with a timestamp.
- A press while already listening is ignored, so a bumped button cannot cut the capture. A double tap or a hold never starts one.
- Each capture restarts the audio frame counter at 0, which gives the tablet a clean boundary between patients.
- If the link drops while listening, audio is dropped (not stored); consent events and markers are queued and sent on reconnect.
- The board has no battery or power switch: plugging in USB powers it, and it starts in "not listening".

### Audio compression

The clip captures 16 kHz, 16-bit mono audio, which is 32,000 bytes per second raw. It compresses
each 20 ms frame with Opus at 32 kbit/s before sending: 80 bytes per frame, 4,400 bytes per
second including frame headers. That fits the roughly 8,000 bytes per second a Bluetooth link
to iOS can carry, with half the budget spare.

A test with Whisper (`codec_test/`, results in `codec_test/results/results.md`) found Opus at
32 kbit/s transcribed as accurately as raw audio, within the test's margin, including in
simulated ambulance noise. Lower bitrates and halving the sample rate were clearly worse.

`AUDIO_OPUS_KBPS` in `include/config.h` sets the bitrate. 0 sends raw audio, which only works
over the Wi-Fi link: a raw frame does not fit in a Bluetooth packet.

### Link to the tablet

| | Bluetooth LE (default) | Wi-Fi |
|---|---|---|
| Setting | `LINK_BLUETOOTH 1` | `LINK_BLUETOOTH 0` in `include/config.h` |
| Who connects | The tablet finds the clip and connects | The clip connects to the tablet's WebSocket server |
| Needs | Nothing shared | Both on the same 2.4 GHz network, and the tablet's address in `config.h` |
| Used by | The iPad app | The laptop simulator and mock tablet |

The messages are the same on both. The simulator and Wokwi cannot do Bluetooth, so they use
Wi-Fi.

## Layout

| Path | What |
|---|---|
| `lib/earshot_core/` | All behaviour: button gestures, state machine, streaming, the Wi-Fi link, the voice-recording player. Portable C++11, no Arduino code |
| `lib/earshot_opus/` | Opus encoder wrapper, shared by the device and the simulator |
| `lib/earshot_voice/` | The voice recording the Feather plays in place of a microphone (generated) |
| `src/main.cpp` | Hardware layer for all three builds: button, light, mic |
| `src/ble_link.cpp` | The Bluetooth LE link |
| `src/build_config.h` | Picks pins, microphone and link for each build |
| `include/config.example.h` | Link choice, Wi-Fi details, pins |
| `BLUETOOTH.md` | App-side guide to the Bluetooth link |
| `tools/ble_receiver.py` | Mac stand-in for the app: connects over Bluetooth, saves and transcribes the audio |
| `tools/flash_feather.sh` | Builds and flashes the Feather |
| `tools/make_voice_clip.py`, `tools/check_voice_clip.py` | Build the voice recording; check it transcribes correctly end to end |
| `host_tests/` | Unit tests for the core, run on the laptop |
| `sim/sim_clip.cpp` | Simulated clip: the same core with a keyboard/UI button, generated audio and a real socket |
| `sim/tablet.py`, `sim/index.html` | Mock tablet and browser UI |
| `sim/e2e_test.py` | Scripted end-to-end check |
| `sim/record_demo.py` | Records a scripted simulator run into `evidence/` |
| `sim/make_wokwi_web.py` | Packages the firmware for the Wokwi website |
| `codec_test/` | Test of compression settings against transcript accuracy, with a listening page |
| `wokwi.toml`, `diagram.json` | Wokwi virtual board setup |

## Simulator

Needs a C++ compiler, Python 3 with `pip install websockets av`, and PlatformIO to fetch the Opus
library once (`pio pkg install -e atom-voices3r`). `av` is what lets the mock tablet decode Opus
for playback; without it audio is still received and counted. If `build/codec-test-venv` exists,
the Makefile uses its Python, which already has both.

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
that must stay at 0, how many times consent was logged, and the data rate against the 8,000
bytes-per-second Bluetooth budget.

### Testing with a microphone

By default the simulated clip hears a test tone. Under **Clip microphone**, choose **Laptop mic**
and allow microphone access: the laptop's microphone then stands in for the clip's microphone.
Open the page in Chrome or Safari for this (http://localhost:8765).

- Speak while the ring is dark: the tablet stays at 0 bytes.
- Press the button (ring green), speak, hold to stop, then press **Play received audio** to hear exactly what the tablet was sent.

The laptop mic tests the whole path with real speech. It does not tell you how the clip's own
microphone sounds; for that, run the real device against `sim/tablet.py --no-sim --lan` and use
the same **Play received audio** button.

You can also feed a recording: `python3 sim/tablet.py --wav call.wav` (16 kHz mono 16-bit WAV).
The simulated clip sends Opus by default, like the device; run `build/sim_clip --pcm` by hand to
try raw audio.

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
build replaces the mic with a 440 Hz tone. It also sends raw audio, because the emulated chip is
too slow to run the Opus encoder in real time. Microphone testing stays with the local simulator
(laptop mic) and the real device.

1. In VS Code, install the **Wokwi Simulator** extension, then F1 → "Wokwi: Request a new License" (free account).
2. Build the Wokwi firmware: `pio run -e wokwi`
3. Start the mock tablet: `python3 sim/tablet.py --no-sim`
4. Open the `firmware/` folder in VS Code, then F1 → "Wokwi: Start Simulator".

Click the blue button (or hold the **B** key) for the clip button. The ring goes green on a
press and dark again on a hold; http://localhost:8765 shows what the virtual clip sent. The
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
the state (dark or green) and the serial monitor prints the clip's state every 5 seconds, but
nothing is streamed. A recorded run of the earlier two-press flow is in
`evidence/2026-11-13-wokwi-run/`.

## Real device

Install PlatformIO first (`pip install platformio`, or the VS Code extension).

### ESP32-S3 Feather (stand-in until the Atom arrives)

The Feather has the same chip as the Atom but no microphone, so this build plays a stored
12.9 second voice recording as if it were the microphone. The BOOT button is the clip's button
and the onboard NeoPixel is the light. No `config.h` is needed for Bluetooth.

1. Plug the Feather into the laptop with a USB-C data cable.
2. Flash it: `tools/flash_feather.sh`. It builds, puts the board into flashing mode, writes the
   firmware and restarts the board. (PlatformIO's own `pio run -e feather-s3 -t upload` does not
   complete on this board: it gives up after the reset, and the board then stays in flashing
   mode.) If the script says the board did not enter flashing mode, hold BOOT, tap RESET,
   release BOOT, and run it again.
3. Watch the log: `pio device monitor`. Every 5 seconds it prints a status line, which should
   include `bluetooth=advertising-as-Earshot-XXXX`. (The start-up lines are usually missed,
   because the monitor connects after the board has booted; press RESET to see them.)
4. Receive on the Mac, from Terminal (macOS asks once to let Terminal use Bluetooth):
   `build/codec-test-venv/bin/python tools/ble_receiver.py --start --seconds 13 --transcribe`
   It should print the events, about 50 packets a second, 0 lost, and the recording's words.
5. Or press BOOT to start, hold it 1.5 s to stop, double tap for a marker, and watch with the
   iPad app, nRF Connect or LightBlue.

The status line every 5 seconds shows the slowest Opus encode so far, which must stay under
20 ms. The first run measured 16.5 ms at worst: it kept up with nothing dropped, but with
little to spare. The Atom has the same chip, so expect the same there.

The build is for the Feather that names itself "Feather ESP32-S3 No PSRAM" when plugged in
(`pio device list`): 8 MB flash, no PSRAM. For another Feather, change `board` in
`platformio.ini`: `adafruit_feather_esp32s3` (4 MB flash, 2 MB PSRAM),
`adafruit_feather_esp32s3_tft` or `adafruit_feather_esp32s3_reversetft`.

### Atom VoiceS3R (the real clip)

1. Put the clip in download mode if needed (hold the reset button about 2 s until the internal green LED lights, then release), then `pio run -e atom-voices3r -t upload`.
2. `pio device monitor` prints a status line every 5 seconds, including the slowest Opus encode so far.
3. Connect from the iPad app, or check with `tools/ble_receiver.py` as above.

Hardware notes for the Atom VoiceS3R:

- Button is G41. The mic goes through the ES8311 codec, driven by M5Unified.
- The board has no RGB LED. The consent ring is an external WS2812 ring on the Grove port (data on G2, yellow wire). Set `LED_COUNT` in `config.h`.

### Over Wi-Fi instead

1. `cp include/config.example.h include/config.h`, set `LINK_BLUETOOTH 0`, and fill in Wi-Fi (2.4 GHz only) and the laptop's IP.
2. Start the mock tablet so a clip on the Wi-Fi can reach it: `python3 sim/tablet.py --no-sim --lan`
3. Flash as above.

Add `--save-wav` to the tablet command to write received audio to `sim/out/` and listen to it.
That flag is a test aid only.

## Protocol

The same messages go over either link. Over Bluetooth each is one packet on its own channel
(see [BLUETOOTH.md](BLUETOOTH.md)); over Wi-Fi the clip connects to `ws://<gateway>:8765/clip`
and sends events as text frames and audio as binary frames. Full definition is in
[`lib/earshot_core/src/protocol.h`](lib/earshot_core/src/protocol.h).

- **Events** (text, JSON): `hello`, `state` (`not_listening`, `listening`), `consent` (`granted`, `stopped`), `marker`.
- **Audio** (binary, only between `granted` and `stopped`): 8-byte header (`uint32 seq`, `uint32 t_ms`, little-endian) followed by one 20 ms frame. The `hello` event names the codec: `opus` (one 80-byte packet at 32 kbit/s) or `pcm` (640 bytes of 16-bit samples).
- **Commands** (text, JSON, tablet to clip): `{"cmd":"start"}`, `stop`, `marker`.

`t_ms` is milliseconds since the clip booted. The tablet should stamp wall-clock time on receipt.
`sim/tablet.py` is a working reference for the tablet side over Wi-Fi, and
`tools/ble_receiver.py` over Bluetooth.

## Porting to another ESP32 board

Add a build to `platformio.ini` and a block to `src/build_config.h` with the board's pins and
microphone, as the Feather has. A board with an I2S microphone needs its read code added beside
the Atom's in `src/main.cpp`. The core, tests and simulator stay as they are.
