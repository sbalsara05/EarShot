// The clip application: button -> consent state machine -> audio streaming once consent is logged.
// Everything here is platform-neutral; the hardware sits behind the Hal interface.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <deque>
#include <string>

#include "button.h"
#include "clip_fsm.h"
#include "protocol.h"
#include "ws_client.h"

namespace earshot {

enum class LedColor : uint8_t { Off, Amber, Green, White };

// Hardware abstraction. One implementation for the ESP32, one for the laptop simulator.
class Hal {
 public:
  virtual ~Hal() {}
  virtual uint32_t millis() = 0;
  virtual void sleepMs(uint32_t ms) = 0;
  virtual bool buttonPressed() = 0;
  virtual void setLed(LedColor color) = 0;
  virtual bool micStart() = 0;
  virtual void micStop() = 0;
  // Fills `out` with exactly `samples` samples and returns `samples`, or returns 0 if a full
  // frame is not ready. May block for up to one frame (20 ms); that paces the main loop.
  virtual size_t micRead(int16_t* out, size_t samples) = 0;
  virtual bool networkUp() = 0;
  virtual void log(const char* message) = 0;
};

struct ClipConfig {
  const char* gateway_host;
  uint16_t gateway_port;
  const char* gateway_path;
  const char* device_id;
  bool poll_button;             // false: the platform detects gestures itself and calls onButtonEvent()
  bool gateway_enabled;         // false: standalone, never tries to reach a tablet (e.g. on wokwi.com)
  uint32_t reconnect_ms;
  uint32_t handshake_timeout_ms;
  uint32_t marker_flash_ms;
  ButtonTiming button;
  ClipConfig()
      : gateway_host("127.0.0.1"),
        gateway_port(8765),
        gateway_path("/clip"),
        device_id("earshot-clip"),
        poll_button(true),
        gateway_enabled(true),
        reconnect_ms(2000),
        handshake_timeout_ms(3000),
        marker_flash_ms(200) {}
};

struct ClipStats {
  uint32_t frames_captured;  // every frame read from the mic (the mic only runs while listening)
  uint32_t frames_sent;      // frames that reached the tablet link
  uint32_t frames_dropped;   // captured while the link was down; not stored
  uint32_t markers;
  uint32_t refusals;         // times a patient declined or withdrew
  ClipStats() : frames_captured(0), frames_sent(0), frames_dropped(0), markers(0), refusals(0) {}
};

class ClipApp {
 public:
  ClipApp(Hal& hal, Transport& transport, const ClipConfig& config, uint32_t random_seed);

  void begin();
  void tick();  // call in a tight loop

  // For platforms that sample the button on their own fast timer (so a tap is never missed
  // while the main loop is busy with the network). Call from the same thread as tick().
  void onButtonEvent(ButtonEvent event);

  ClipState state() const { return state_; }
  const ClipStats& stats() const { return stats_; }
  bool linkOpen() const { return announced_ && ws_.isOpen(); }

 private:
  void apply(Input input, const char* source);
  void emit(const std::string& json);
  void serviceLink(uint32_t now);
  void announce(uint32_t now);
  void serviceAudio(uint32_t now);
  void refreshLed(uint32_t now, bool force);

  Hal& hal_;
  ClipConfig cfg_;
  WsClient ws_;
  Button button_;
  ClipState state_;
  ClipStats stats_;

  bool announced_;        // hello sent on the current connection
  bool tried_connect_;
  uint32_t last_attempt_;
  std::deque<std::string> pending_;  // events (never audio) waiting for the link

  uint32_t audio_seq_;
  int16_t frame_[kFrameSamples];

  bool flashing_;
  uint32_t flash_start_;
  LedColor led_;
};

}  // namespace earshot
