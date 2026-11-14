# Earshot wire format (protocol version 1)

Byte-level spec for everything that crosses the clip ↔ iPad link. Same packets on every transport (BLE, Wi-Fi, replay files).
Source of truth in code: `firmware/common/earshot_proto.h` (C) and `core/Sources/EarshotCore/Wire/Packet.swift` (Swift); a test checks they agree bit for bit (`WireTests.testADPCMMatchesFirmwareVector`, `firmware/common/test`).

All integers are **little-endian**.

## Header (7 bytes)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `type` | `0x01` audio · `0x02` tap · `0x03` state · `0x04` clock · `0x05` ack |
| 1 | 2 | `seq` | **Per-type** counter, wraps at 65536. Audio gaps are detected from audio `seq` alone; tap `seq` is the ack id. |
| 3 | 4 | `clip_ms` | Milliseconds since the clip booted (`millis()`), at send time. |

## Payloads

### audio `0x01` — clip → iPad, 164 bytes (packet = 171 bytes)
One 20 ms frame: 320 samples, 16 kHz mono, IMA ADPCM 4-bit.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | predictor (int16) — encoder state **before** the first sample |
| 2 | 1 | step index (0–88) |
| 3 | 1 | reserved, 0 |
| 4 | 160 | 320 × 4-bit codes, low nibble first |

Each frame decodes on its own (state is in its header), so a lost frame never corrupts the next one. `clip_ms` of consecutive frames advances by 20 ms per `seq` step. Bitrate: 171 B × 50/s = **68.4 kbps** (BLE adds ~3 B/notification).

### tap `0x02` — clip → iPad, 6 bytes

| Offset | Size | Field | Values |
|---|---|---|---|
| 0 | 1 | gesture | 0 mark · 1 start · 2 stop · 3 yes · 4 no |
| 1 | 1 | source | 0 button (the only tap input). 1 and 2 (knock, snap) are retired and rejected. 3 tablet is iPad-only and never sent by a clip |
| 2 | 4 | press_clip_ms | clip time of the press / first hit (≤ header `clip_ms`) |

Resent every 500 ms with the **same `seq`** until acked.

### state `0x03`
clip → iPad, 3 bytes: `state` u8 (0 OFF · 1 ASKING · 2 LISTENING · 3 REFUSED), `flags` u8 (bit0 USB power, bit1 battery low, bit2 tone playing / mic muted), `proto_version` u8 (= 1).

iPad → clip write, 2 bytes: `state` u8 (**only 0 OFF is honoured**: force stop), `flags` u8 (ignored).

### clock `0x04` — iPad → clip, 8 bytes
`epoch_ms` u64: iPad wall clock (Unix ms) when written. The clip keeps `offset = epoch_ms − millis()`; the iPad maps tap `press_clip_ms` to wall time with the same pair.

### ack `0x05` — iPad → clip, 2 bytes
`acked_seq` u16: the tap `seq` being acknowledged.

## Transports

### BLE (primary)
GATT service `E5A1D000-0B5E-4C6B-9C5E-EA5407000000`, advertised; device name `Earshot`.

| Characteristic | UUID suffix | Properties | Contents |
|---|---|---|---|
| audio | `…D001…` | notify (encrypted) | one audio packet per notification |
| tap | `…D002…` | notify (encrypted) | one tap packet per notification |
| state | `…D003…` | read, notify, write (encrypted) | clip state packet / iPad force-off |
| clock | `…D004…` | write (encrypted) | clock packet |
| ack | `…D005…` | write without response (encrypted) | ack packet |

(Full UUIDs: replace `D000` with the suffix, e.g. audio = `E5A1D001-0B5E-4C6B-9C5E-EA5407000000`.)
One packet per notification/write, **no length prefix**. Link setup (peripheral side): MTU 247, 2M PHY, data-length extension 251, connection interval 15 ms (iOS minimum), encrypted bonding (LE Secure Connections, Just Works).

### Wi-Fi (fallback)
Clip runs a WPA2 soft AP `Earshot-XXXX` at `192.168.4.1`; TCP port **7070**; one client. Stream framing: `u16 length` + packet, both directions.

### Replay files
Exactly the Wi-Fi stream framing, concatenated (`.replay`). A TCP capture of a clip is already a replay file. `earshot-eval make-replay` writes them from WAV for tests; the iPad app never writes audio to disk.

## Versioning
`proto_version` in clip state packets. Any incompatible change bumps it; the iPad refuses streams with an unknown version (conformance check W2).
