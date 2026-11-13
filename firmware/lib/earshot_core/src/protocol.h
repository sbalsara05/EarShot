// Wire protocol between the clip and the tablet gateway (WebSocket, path /clip).
//
// Clip -> tablet, text frames (JSON):
//   {"type":"hello","device":"earshot-clip","fw":"0.3.0","audio":{"rate":16000,"bits":16,"channels":1,"frame_ms":20}}
//   {"type":"state","state":"not_listening|asking|listening","listening":bool,"t_ms":N}
//   {"type":"consent","event":"asked|granted|declined|stopped","source":"button|tablet","t_ms":N}
//   {"type":"marker","id":N,"source":"button|tablet","t_ms":N,"audio_seq":N}
//
//   consent events:
//     asked     the medic started the consent ask (ring amber). Nothing is captured yet.
//     granted   consent logged. Capture starts; audio frames follow.
//     declined  the patient said no while being asked, or withdrew during capture. A refusal.
//     stopped   the medic or the tablet ended the capture, or cancelled the ask.
//
// Clip -> tablet, binary frames (audio, only between "granted" and "declined"/"stopped"):
//   bytes 0..3  uint32 LE  seq    frame counter, restarts at 0 with each "granted";
//                                 a gap means frames were lost
//   bytes 4..7  uint32 LE  t_ms   clip clock when the frame was captured
//   bytes 8..   int16 LE PCM, mono, 16 kHz, 20 ms (320 samples = 640 bytes)
//
// Tablet -> clip, text frames (JSON):
//   {"cmd":"ask"}              start the consent ask
//   {"cmd":"consent_grant"}    log consent and start capture (also valid without a prior ask)
//   {"cmd":"consent_decline"}  log a refusal / withdrawal and stop
//   {"cmd":"stop"}             end the capture
//   {"cmd":"marker"}           drop a timestamp marker (while listening)
//
// t_ms is milliseconds since the clip booted (it has no real-time clock). The tablet should
// stamp wall-clock time on receipt.
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
static const char kFirmwareVersion[] = "0.3.0";

std::string helloJson(const char* device_id);
std::string stateJson(ClipState state, uint32_t t_ms);
std::string consentJson(const char* event, const char* source, uint32_t t_ms);
std::string markerJson(uint32_t id, const char* source, uint32_t t_ms, uint32_t audio_seq);

// Parses a tablet command. Returns false for anything unrecognised.
bool parseCommand(const std::string& json, Input& out);

void putLe32(uint8_t* dst, uint32_t value);

}  // namespace earshot
