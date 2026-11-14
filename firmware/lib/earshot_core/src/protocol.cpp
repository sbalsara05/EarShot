#include "protocol.h"

#include <stdio.h>
#include <string.h>

namespace earshot {

std::string helloJson(const char* device_id, const char* codec, uint32_t bitrate) {
  char buf[240];
  snprintf(buf, sizeof buf,
           "{\"type\":\"hello\",\"device\":\"%s\",\"fw\":\"%s\","
           "\"audio\":{\"codec\":\"%s\",\"rate\":%u,\"channels\":1,\"frame_ms\":%u,\"bitrate\":%lu}}",
           device_id, kFirmwareVersion, codec, (unsigned)kSampleRate, (unsigned)kFrameMs,
           (unsigned long)bitrate);
  return buf;
}

std::string stateJson(ClipState state, uint32_t t_ms) {
  char buf[120];
  snprintf(buf, sizeof buf, "{\"type\":\"state\",\"state\":\"%s\",\"listening\":%s,\"t_ms\":%lu}",
           stateName(state), state == ClipState::Listening ? "true" : "false",
           (unsigned long)t_ms);
  return buf;
}

std::string consentJson(const char* event, const char* source, uint32_t t_ms) {
  char buf[120];
  snprintf(buf, sizeof buf, "{\"type\":\"consent\",\"event\":\"%s\",\"source\":\"%s\",\"t_ms\":%lu}",
           event, source, (unsigned long)t_ms);
  return buf;
}

std::string markerJson(uint32_t id, const char* source, uint32_t t_ms, uint32_t audio_seq) {
  char buf[140];
  snprintf(buf, sizeof buf,
           "{\"type\":\"marker\",\"id\":%lu,\"source\":\"%s\",\"t_ms\":%lu,\"audio_seq\":%lu}",
           (unsigned long)id, source, (unsigned long)t_ms, (unsigned long)audio_seq);
  return buf;
}

bool parseCommand(const std::string& json, Input& out) {
  // Tiny extractor for {"cmd":"..."}; avoids pulling a JSON library onto the device.
  size_t k = json.find("\"cmd\"");
  if (k == std::string::npos) return false;
  size_t colon = json.find(':', k + 5);
  if (colon == std::string::npos) return false;
  size_t q1 = json.find('"', colon + 1);
  if (q1 == std::string::npos) return false;
  size_t q2 = json.find('"', q1 + 1);
  if (q2 == std::string::npos) return false;
  std::string cmd = json.substr(q1 + 1, q2 - q1 - 1);

  if (cmd == "start") out = Input::CmdStart;
  else if (cmd == "stop") out = Input::CmdStop;
  else if (cmd == "marker") out = Input::CmdMarker;
  else if (cmd == "find") out = Input::CmdFind;
  else return false;
  return true;
}

void putLe32(uint8_t* dst, uint32_t v) {
  dst[0] = (uint8_t)(v & 0xFF);
  dst[1] = (uint8_t)((v >> 8) & 0xFF);
  dst[2] = (uint8_t)((v >> 16) & 0xFF);
  dst[3] = (uint8_t)((v >> 24) & 0xFF);
}

}  // namespace earshot
