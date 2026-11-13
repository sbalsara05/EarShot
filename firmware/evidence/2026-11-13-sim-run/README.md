# Simulator run, 13 Nov 2026

A recorded run of the Earshot clip firmware 0.5.0 in the laptop simulator, 15:59:06 to 15:59:39
local time. The firmware uses a one-press flow (press to start, with consent logged; hold to
stop; double tap for a marker) and sends audio compressed with Opus at 32 kbit/s.

## What ran

- **Clip:** the firmware core (`lib/earshot_core`) and the Opus encoder (`lib/earshot_opus`, the same library the device build uses) compiled for the laptop as `build/sim_clip`. Its microphone was a generated test tone.
- **Tablet:** `sim/tablet.py`, a mock of the tablet side, receiving over a real WebSocket on localhost and decoding the Opus audio.
- **Driver:** `sim/record_demo.py` opened the simulator page in headless Chrome, pressed the clip button with real mouse press and release timings, and captured the screen six times a second.

Reproduce with `make sim && build/codec-test-venv/bin/python sim/record_demo.py`.

## Files

| File | What it is |
|---|---|
| `recording.mp4` | The run in real time (37 s). The bar at the bottom names each step and shows the clock. Not kept in git |
| `step-01.png` … `step-09.png` | One still per step |
| `messages.jsonl` | Every message between clip and tablet with wall-clock times, plus the tablet's ledger whenever it changed |
| `test-output.txt` | Output of the unit tests (183 checks) and the scripted end-to-end check (39 checks) |

## What the run shows

| Step | Action | Result |
|---|---|---|
| 1 | Power on | Ring dark, not listening. Mic off: 0 frames captured, tablet received 0 bytes |
| 2 | Press | Consent logged at 15:59:11.110, ring green, audio starts arriving |
| 3 | Double tap | Marker 1 at 15:59:15.095, ring flashes white |
| 4 | Press while listening | Ignored: no new message, capture continues |
| 5 | Hold | Capture stopped at 15:59:22.273, ring dark, tablet total stops at 44,640 bytes |
| 6 | Press (next patient) | Consent logged again at 15:59:26.577, new capture, ring green |
| 7 | Hold | Capture stopped at 15:59:31.240, total 63,280 bytes |
| 8 | Tablet sends `start` | Consent logged at 15:59:34.621, ring green, audio arrives |
| 9 | Tablet sends `stop` | Capture stopped at 15:59:38.225 |

Totals at the end: the clip captured 971 frames (19.4 seconds of audio), all of them while
listening, and sent all 971. The tablet received 77,680 bytes of audio: 80 bytes per frame, or
4,000 bytes per second (4,400 with frame headers). The same audio uncompressed would have been
621,440 bytes. No frames were lost, no audio arrived while the clip was not listening, and
consent was logged three times, once per capture.

## What this does and does not show

It shows the firmware's logic doing what it should: gestures, the listening state, consent
logging, markers, and Opus-compressed audio that the tablet can decode, end to end over a real
socket.

It does not show the physical clip. The real microphone, LED ring, button and Wi-Fi on the
M5Stack Atom VoiceS3R were not involved, the microphone here was a test tone, and the button
presses were scripted rather than made by a person. In particular, whether the ESP32 can encode
Opus fast enough has not been measured: the device firmware prints its slowest encode time so
that can be checked on the first flash.
