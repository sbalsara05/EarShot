# Clip firmware contract

What any Earshot clip (Atom VoiceS3R, Feather fallback, or anything else) must do so the iPad pipeline works. Board code is not in this repo; this is the interface it must meet.

- Bytes on the wire: [`WIRE_FORMAT.md`](WIRE_FORMAT.md).
- Portable reference C you can compile straight into firmware: [`firmware/common`](../firmware/common) (no RTOS/Arduino dependencies, host-tested with `make -C firmware/common/test`).
- Executable reference: `earshot-eval fake-clip` (a clip over TCP).
- Acceptance: `earshot-eval check-stream` on a capture from your board (IDs below).

**MUST** = required for the pipeline / product rules. **SHOULD** = expected for a good demo.

## 1. Consent and capture (product rule: nothing captured before a "yes")

| ID | Requirement | Reference | Checked by |
|---|---|---|---|
| FW-C1 | **MUST** send no audio packet unless the state is LISTENING. | `es_sm_audio_allowed()` | check-stream **C1** |
| FW-C2 | **MUST** follow the state machine below; the only legal transitions are OFF→ASKING, ASKING→LISTENING, ASKING→OFF (refusal, may pass through REFUSED), LISTENING→OFF. | `state_machine.c` | check-stream **C2**, host tests |
| FW-C3 | **MUST** send a state packet on every change and at least every 2 s while connected (≤ 5 s worst case). | — | check-stream **S1** |
| FW-C4 | **MUST** on stop, refusal or iPad force-OFF: go OFF and zero every audio buffer (resend ring included). | `es_ring_clear()` | host tests |
| FW-C5 | **MUST** never write audio to flash/NVS/SD. Audio lives only in RAM (PSRAM is RAM). | — | code review |
| FW-C6 | **MUST** log a refusal (serial is enough) and emit the `no` tap. | `es_action.log_refusal` | host tests |
| FW-C7 | **MUST** honour an iPad state write with state OFF (force stop). Any other state value from the iPad is ignored: the iPad can never start capture. | `es_parse_incoming()` | host tests |

### State machine (button build)

| State | Gesture | → State | Tap sent | Feedback |
|---|---|---|---|---|
| OFF | single press | ASKING | `start` | rising two-tone |
| ASKING | single press (patient said yes) | LISTENING | `yes` | one high tone |
| ASKING | long press ≥ 1.5 s (patient said no) | OFF (log refusal) | `no` | one low tone |
| LISTENING | single press | LISTENING | `mark` (source button) | short click |
| LISTENING | long press ≥ 1.5 s | OFF, clear buffers | `stop` | falling two-tone |
| any | iPad writes state OFF | OFF, clear buffers | — | falling two-tone |

The button is the only input. There is no knock/snap detection: a clip without a working button cannot be used.
Single press = release before 1.5 s (debounce 30 ms); the tap's `press_clip_ms` is the press-down time. Long press fires while still held.

## 2. Audio

| ID | Requirement | Reference | Checked by |
|---|---|---|---|
| FW-A1 | **MUST** send 16 kHz mono, 20 ms frames, IMA ADPCM per WIRE_FORMAT (164-byte payload, per-frame state header). | `es_audio_packet()`, `adpcm.c` | check-stream **W1**, Swift↔C vector test |
| FW-A2 | **MUST** increment audio `seq` by exactly 1 per frame and stamp `clip_ms` 20 ms apart (±5 ms). | `es_audio_packet()` | check-stream **A2** |
| FW-A3 | **MUST** sustain < 1 % frame loss over 2 min at the bench (iPad 1 m away). | — | check-stream **A1**, app throughput test |
| FW-A4 | **MUST** mute the mic while a tone plays and for 200 ms after: send silence frames (keep `seq` running). | — | — |
| FW-A5 | **SHOULD** keep the last 3 s of encoded frames in RAM and, after a link drop of < 3 s, resend frames captured since 500 ms before the drop (same `seq`; the iPad drops duplicates). | `es_ring_*` | host tests |
| FW-A6 | **SHOULD** read audio before encoding at a gain where normal speech at 30 cm peaks around −12 dBFS (VoiceS3R ES8311: PGA ≈ 24 dB). | — | bench |

## 3. Taps

| ID | Requirement | Reference | Checked by |
|---|---|---|---|
| FW-T1 | **MUST** send every gesture as a tap packet with source `button` (0). Sources 1/2 (knock/snap) are retired and rejected by the iPad. | `es_tapq_push()` | check-stream **W1** |
| FW-T2 | **MUST** resend each tap every 500 ms (same `seq`) until acked; queue ≥ 16 taps; if full, drop the oldest and count it. | `es_tap_queue` | host tests, check-stream `taps_resent` |
| FW-T3 | **MUST** set `press_clip_ms` to the press-down time, never after the packet's `clip_ms`, at most 3 s before it. | — | check-stream **T2** |
| FW-T4 | **MUST NOT** send `mark` outside LISTENING. | state machine | check-stream **T1** |


## 4. Link

| ID | Requirement | Checked by |
|---|---|---|
| FW-L1 | **MUST** expose the GATT service exactly as in WIRE_FORMAT (UUIDs, properties, encrypted). | app connects |
| FW-L2 | **SHOULD** request MTU 247, 2M PHY, DLE 251 and a 15 ms connection interval on connect. If throughput (A3) fails, drop to 8 kHz or a lower ADPCM rate before abandoning BLE (needs a `proto_version` bump). | app throughput test |
| FW-L3 | **MUST** keep advertising after a disconnect and keep capturing to the RAM ring while disconnected (LISTENING continues). | bench |
| FW-L4 | **SHOULD** run the Wi-Fi soft AP fallback (`Earshot-XXXX`, WPA2, 192.168.4.1:7070, length-prefixed TCP). | `capture_clip.py`, app Wi-Fi source |
| FW-L5 | **MUST** apply a clock packet by storing `offset = epoch_ms − millis()` (used for logs; the iPad does the mapping). | — |
| FW-L6 | **MUST** report `proto_version = 1` in every state packet. | check-stream **W2** |

## 5. Feedback

No screen is needed. VoiceS3R: short distinct tones on the speaker (rising two-tone, high, low, click, falling two-tone); optional WS2812 on Grove G2 as consent light (red = LISTENING, amber = ASKING) behind a compile-time flag. Feather: vibration pulses (2 / 1 / 3 / short / 2) and the OLED shows the state and the next gesture.

## Bring-up checklist (in order)

1. `make -C firmware/common/test` passes on your machine, and the board build compiles `firmware/common/*.c` unchanged.
2. Serial log shows `proto_version 1`, state changes and refusals.
3. **Wi-Fi first** (easiest to capture): join `Earshot-XXXX`, then
   `python3 core/tools/capture_clip.py 192.168.4.1 7070 capture.replay --seconds 120`
   while you do: press (ASKING) → press (yes) → talk, press a few times → long press (stop).
4. `earshot-eval check-stream capture.replay` → every line PASS, `audio_kbps ≈ 68`, `loss_pct < 1`.
5. `earshot-eval run capture.replay --asr-model models/ggml-small.en.bin` → your speech appears in `transcript.raw.json`, taps in `events.json` with the right `tap_source`.
6. BLE: app → *BLE throughput test* for 2 minutes: ≥ 80 kbps, < 1 % loss.

Use test speech for captures (they contain audio). Never capture a patient.
