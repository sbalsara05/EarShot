# Simulator run, 13 Nov 2026

A recorded run of the Earshot clip firmware 0.3.0 in the laptop simulator, 10:20:19 to 10:20:51
local time. The firmware follows the PRD consent flow: press to ask, press again for the
patient's yes, hold to stop or to log a no.

## What ran

- **Clip:** the firmware core (`lib/earshot_core`: button gestures, consent states, streaming) compiled for the laptop as `build/sim_clip`. Its microphone was a generated test tone.
- **Tablet:** `sim/tablet.py`, a mock of the tablet side, receiving over a real WebSocket on localhost.
- **Driver:** `sim/record_demo.py` opened the simulator page in headless Chrome, pressed the clip button with real mouse press and release timings, and captured the screen six times a second.

Reproduce with `make sim && python3 sim/record_demo.py`.

## Files

| File | What it is |
|---|---|
| `recording.mp4` | The run in real time (38 s). The bar at the bottom names each step and shows the clock. Not kept in git |
| `step-01.png` … `step-09.png` | One still per step |
| `messages.jsonl` | Every message between clip and tablet with wall-clock times, plus the tablet's ledger whenever it changed |
| `test-output.txt` | Output of the unit tests (211 checks) and the scripted end-to-end check (41 checks) |

## What the run shows

| Step | Action | Result |
|---|---|---|
| 1 | Power on | Ring dark, not listening. Mic off: 0 frames captured, tablet received 0 bytes |
| 2 | Press | Consent ask logged at 10:20:22.812, ring amber. Still 0 frames captured, 0 bytes |
| 3 | Press again | Consent granted at 10:20:26.444, ring green, audio starts arriving |
| 4 | Double tap | Marker 1 at 10:20:29.947, ring flashes white |
| 5 | Hold | Capture stopped at 10:20:34.487, ring dark, tablet total stops at 257,280 bytes |
| 6 | Press (second patient) | Ask logged at 10:20:38.283, ring amber, total still 257,280 bytes |
| 7 | Hold while asking | Refusal logged at 10:20:42.460, ring dark. Nothing was captured or sent for this patient |
| 8 | Tablet sends `ask`, then `consent_grant` | Ask at 10:20:46.318, consent at 10:20:47.916, ring green, audio arrives |
| 9 | Tablet sends `stop` | Capture stopped at 10:20:51.017 |

Totals at the end: the clip captured 557 frames, all of them while listening with consent, and
sent all 557. The tablet received 356,480 bytes (557 × 640), with 0 frames lost and 0 audio
frames received while the clip was not listening. One refusal was logged.

## What this does and does not show

It shows the firmware's logic doing what it should: gestures, consent states, refusal logging,
markers and the stream format, end to end over a real socket.

It does not show the physical clip. The real microphone, LED ring, button and Wi-Fi on the
M5Stack Atom VoiceS3R were not involved, the microphone here was a test tone, and the button
presses were scripted rather than made by a person.
