// The clip application: button -> state machine -> audio streaming while listening.
// Everything here is platform-neutral; the hardware sits behind the Hal interface.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <deque>
#include <string>

#include "audio_encoder.h"
#include "button.h"
#include "clip_fsm.h"
#include "hal.h"
#include "link.h"
#include "protocol.h"
#include "ws_link.h"

namespace earshot {

struct ClipConfig {
  const char* gateway_host;     // gateway_* and the two timeouts apply to the Wi-Fi link only
  uint16_t gateway_port;
  const char* gateway_path;
  const char* device_id;
  bool poll_button;             // false: the platform detects gestures itself and calls onButtonEvent()
  bool gateway_enabled;         // false: standalone, never tries to reach a tablet (e.g. on wokwi.com)
  AudioEncoder* encoder;        // how frames are encoded for the link; null = uncompressed PCM
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
        encoder(NULL),
        reconnect_ms(2000),
        handshake_timeout_ms(3000),
        marker_flash_ms(200) {}
};

struct ClipStats {
  uint32_t frames_captured;  // every frame read from the mic (the mic only runs while listening)
  uint32_t frames_sent;      // frames that reached the tablet link
  uint32_t frames_dropped;   // captured while the link was down (or failed to encode); not stored
  uint32_t audio_bytes_sent; // encoded audio bytes sent, excluding the 8-byte frame header
  uint32_t markers;
  uint32_t captures;         // times capture was started
  ClipStats()
      : frames_captured(0), frames_sent(0), frames_dropped(0), audio_bytes_sent(0), markers(0),
        captures(0) {}
};

class ClipApp {
 public:
  // Wi-Fi: the clip opens a WebSocket to the tablet gateway named in `config`.
  ClipApp(Hal& hal, Transport& transport, const ClipConfig& config, uint32_t random_seed);
  // Any other link (Bluetooth): the caller owns it and it must outlive the app.
  ClipApp(Hal& hal, Link& link, const ClipConfig& config);
  ~ClipApp();

  void begin();
  void tick();  // call in a tight loop

  // For platforms that sample the button on their own fast timer (so a tap is never missed
  // while the main loop is busy with the network). Call from the same thread as tick().
  void onButtonEvent(ButtonEvent event);

  ClipState state() const { return state_; }
  const ClipStats& stats() const { return stats_; }
  bool linkOpen() const { return announced_ && link_->isOpen(); }

 private:
  ClipApp(const ClipApp&);             // not copyable
  ClipApp& operator=(const ClipApp&);

  void init();
  void apply(Input input, const char* source);
  void emit(const std::string& json);
  void flushPending();
  void serviceLink(uint32_t now);
  void announce(uint32_t now);
  void serviceAudio(uint32_t now);
  void refreshLed(uint32_t now, bool force);

  Hal& hal_;
  ClipConfig cfg_;
  WsLink* own_link_;  // the built-in Wi-Fi link, when constructed with a Transport
  Link* link_;
  Button button_;
  ClipState state_;
  ClipStats stats_;

  bool announced_;        // hello sent on the current connection
  std::deque<std::string> pending_;  // events (never audio) waiting for the link

  PcmEncoder pcm_;
  AudioEncoder* enc_;
  uint32_t audio_seq_;
  int16_t frame_[kFrameSamples];
  uint8_t packet_[kFrameSamples * 2];  // one encoded frame; PCM is the largest case

  bool flashing_;
  uint32_t flash_start_;
  LedColor led_;
};

}  // namespace earshot
