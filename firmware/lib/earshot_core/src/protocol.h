// Messages between the clip and the tablet. The same messages go over either link:
//
//   Bluetooth LE   one message per packet, on the three channels listed at the end of this
//                  comment (and in BLUETOOTH.md, which is written for the app side)
//   Wi-Fi          WebSocket to the tablet gateway, path /clip: JSON as text frames, audio as
//                  binary frames
//
// Clip -> tablet, text (JSON):
//   {"type":"hello","device":"earshot-clip","fw":"0.7.0",
//    "audio":{"codec":"opus|pcm","rate":16000,"channels":1,"frame_ms":20,"bitrate":32000}}
//   {"type":"state","state":"not_listening|listening","listening":bool,"t_ms":N}
//   {"type":"consent","event":"granted|stopped","source":"button|tablet","t_ms":N}
//   {"type":"marker","id":N,"source":"button|tablet","t_ms":N,"audio_seq":N}
//
//   consent events:
//     granted   the medic pressed start (or the tablet sent "start"): consent is taken as given
//               and logged. Capture starts; audio frames follow.
//     stopped   the medic or the tablet ended the capture.
//
// Clip -> tablet, binary (audio, only between "granted" and "stopped"):
//   bytes 0..3  uint32 LE  seq    frame counter, restarts at 0 with each "granted";
//                                 a gap means frames were lost
//   bytes 4..7  uint32 LE  t_ms   clip clock when the frame was captured
//   bytes 8..   one 20 ms frame of 16 kHz mono audio, in the codec named in "hello":
//                 opus  one Opus packet (80 bytes at 32 kbit/s, constant bitrate)
//                 pcm   320 samples, int16 LE (640 bytes)
//
// Tablet -> clip, text (JSON):
//   {"cmd":"start"}    log consent and start capture
//   {"cmd":"stop"}     end the capture
//   {"cmd":"marker"}   drop a timestamp marker (while listening)
//   {"cmd":"find"}     blink and beep for a few seconds so the clip can be found. Works whether
//                      or not it is listening; while listening it only blinks, so the beep
//                      never lands in a recording. Sending it again restarts the timer.
//
// t_ms is milliseconds since the clip booted (it has no real-time clock). The tablet should
// stamp wall-clock time on receipt.
//
// Bluetooth LE: the clip is the peripheral and advertises one service. The tablet connects,
// then subscribes to the two "notify" channels; the clip introduces itself ("hello", then
// "state") as soon as the events channel is subscribed.
//   service   e5a70001-7c1b-4f0e-9d52-3a6b8c4d2e10
//   audio     e5a70002-...   notify   one audio frame per packet (the binary layout above)
//   events    e5a70003-...   notify   one JSON message per packet
//   commands  e5a70004-...   write    one JSON command per write
// Every message fits in one packet: none is longer than kBleMaxMessage bytes, which is inside
// the 182 bytes iOS allows. Raw PCM audio (640 bytes a frame) does not fit; Bluetooth needs Opus.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string>

#include "clip_fsm.h"

namespace earshot {

static const uint32_t kSampleRate = 16000;
static const uint32_t kFrameMs = 20;
static const size_t kFrameSamples = 320;  // kSampleRate * kFrameMs / 1000
static const size_t kAudioHeaderBytes = 8;
static const char kFirmwareVersion[] = "0.7.0";

static const char kBleServiceUuid[] = "e5a70001-7c1b-4f0e-9d52-3a6b8c4d2e10";
static const char kBleAudioUuid[] = "e5a70002-7c1b-4f0e-9d52-3a6b8c4d2e10";
static const char kBleEventUuid[] = "e5a70003-7c1b-4f0e-9d52-3a6b8c4d2e10";
static const char kBleCommandUuid[] = "e5a70004-7c1b-4f0e-9d52-3a6b8c4d2e10";
static const size_t kBleMaxMessage = 160;  // longest message the clip sends over Bluetooth

std::string helloJson(const char* device_id, const char* codec, uint32_t bitrate);
std::string stateJson(ClipState state, uint32_t t_ms);
std::string consentJson(const char* event, const char* source, uint32_t t_ms);
std::string markerJson(uint32_t id, const char* source, uint32_t t_ms, uint32_t audio_seq);

// Parses a tablet command. Returns false for anything unrecognised.
bool parseCommand(const std::string& json, Input& out);

void putLe32(uint8_t* dst, uint32_t value);

}  // namespace earshot
