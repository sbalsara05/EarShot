# Wokwi run, 13 Nov 2026

> This run was recorded with firmware 0.3.0, which used a two-press consent flow (press to ask,
> press again for yes, hold while asking to log a refusal). The firmware has since changed to one
> press to start. The button, LED ring and Wi-Fi code this run exercises are the same.

The Earshot clip firmware 0.3.0 running on Wokwi's website (wokwi.com) on a virtual ESP32-S3,
captured around 10:10 local time. Unlike the laptop simulator, Wokwi compiles the firmware for
the ESP32 and runs that program on an emulated chip, so this exercises the hardware layer too:
the button pin, the LED ring driver and Wi-Fi.

## What ran

- **Board:** Wokwi's ESP32-S3-DevKitC-1, with a pushbutton on G41 and a 12-pixel WS2812 ring on G2 (the same pins as the M5Stack Atom VoiceS3R build).
- **Firmware:** the files in `project/`, generated from the repo by `sim/make_wokwi_web.py` and built by Wokwi's own compiler. The code Wokwi built was checked against the local file by SHA-256 before the run.
- **Button presses:** scripted mouse-down and mouse-up events on Wokwi's virtual button, held for 250 ms (press), 90 ms twice (double tap) or 1.8 s (hold).

## Files

| File | What it is |
|---|---|
| `recording.mp4` | The eight steps as a captioned slideshow (3 s per step). It is a sequence of screenshots, not real-time video. Not kept in git |
| `step-01.png` … `step-08.png` | The screenshot for each step. Wokwi's simulation clock is in the top right |
| `serial-log.txt` | The virtual clip's serial output for the whole run |
| `project/` | The exact files used. Paste them into https://wokwi.com/projects/new/esp32-s3 to reproduce |

## What the run shows

| Step | Action | Ring | Serial log |
|---|---|---|---|
| 1 | Power on | Dark | `state=not_listening`, `captured=0` |
| 2 | Press | Amber | `state=asking`, `captured=0` |
| 3 | Press again | Green | |
| 4 | | Green | `state=listening`, `captured=55` and rising |
| 5 | Double tap | Green | `markers=1`, still listening |
| 6 | Hold | Dark | `state=not_listening`, capture stopped at 330 frames |
| 7 | Press (second patient) | Amber | `state=asking`, `captured` still 330 |
| 8 | Hold while asking | Dark | `state=not_listening`, `refusals=1`, `captured` still 330 |

## What this does and does not show

It shows the compiled ESP32 firmware reading a real GPIO button (with Wokwi's simulated contact
bounce), driving a WS2812 ring, joining Wi-Fi, and following the consent flow.

Three limits:

- **No tablet.** Wokwi's website cannot reach a tablet on a laptop, so this build is standalone: it never looks for one, and every captured frame is counted as `dropped` (`sent=0`, `link=closed`). Streaming to a tablet is shown in `../2026-11-13-sim-run/`.
- **No microphone.** Wokwi cannot simulate the microphone bus on the ESP32-S3, so the mic is a generated tone. The frame rate in the log is lower than the real 50 per second because generating that tone is slow on an emulated chip.
- **Not the physical clip.** The real M5Stack Atom VoiceS3R has not been flashed.

Two display settings differ from the device build so the virtual ring is readable: full LED
brightness, and no "not connected" blink (there is nothing to connect to).
