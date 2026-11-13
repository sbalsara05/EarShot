#include "clip_app.h"

#include <string.h>

namespace earshot {

namespace {
const size_t kMaxPendingEvents = 32;
}

ClipApp::ClipApp(Hal& hal, Transport& transport, const ClipConfig& config, uint32_t random_seed)
    : hal_(hal),
      cfg_(config),
      ws_(transport, random_seed),
      button_(config.button),
      state_(ClipState::NotListening),
      announced_(false),
      tried_connect_(false),
      last_attempt_(0),
      enc_(config.encoder ? config.encoder : &pcm_),
      audio_seq_(0),
      flashing_(false),
      flash_start_(0),
      led_(LedColor::Off) {
  memset(frame_, 0, sizeof frame_);
}

void ClipApp::begin() {
  // Power-on state: not listening, mic off, ring dark. Nothing happens until the medic presses.
  refreshLed(hal_.millis(), true);
}

void ClipApp::tick() {
  uint32_t now = hal_.millis();

  if (cfg_.poll_button) onButtonEvent(button_.update(hal_.buttonPressed(), now));

  serviceLink(now);
  serviceAudio(now);
  refreshLed(hal_.millis(), false);
}

void ClipApp::onButtonEvent(ButtonEvent event) {
  switch (event) {
    case ButtonEvent::ShortPress: apply(Input::ShortPress, "button"); break;
    case ButtonEvent::LongPress: apply(Input::LongPress, "button"); break;
    case ButtonEvent::DoubleTap: apply(Input::DoubleTap, "button"); break;
    case ButtonEvent::None: break;
  }
}

void ClipApp::apply(Input input, const char* source) {
  uint32_t now = hal_.millis();
  Transition tr = step(state_, input);
  state_ = tr.next;

  switch (tr.effect) {
    case Effect::None:
      return;
    case Effect::Started:
      // Pressing start is the medic's confirmation of consent. It is logged first; only then
      // does the microphone start.
      emit(consentJson("granted", source, now));
      audio_seq_ = 0;
      enc_->reset();  // no codec state carries over from the previous capture
      ++stats_.captures;
      if (!hal_.micStart()) hal_.log("mic failed to start");
      break;
    case Effect::Stopped:
      hal_.micStop();
      memset(frame_, 0, sizeof frame_);
      memset(packet_, 0, sizeof packet_);
      emit(consentJson("stopped", source, now));
      break;
    case Effect::Marker:
      ++stats_.markers;
      flashing_ = true;
      flash_start_ = now;
      emit(markerJson(stats_.markers, source, now, audio_seq_));
      return;  // state did not change
  }
  emit(stateJson(state_, now));
}

void ClipApp::emit(const std::string& json) {
  if (linkOpen() && ws_.sendText(json)) return;
  // Link is down: keep the event (consent changes and markers must not be lost).
  if (pending_.size() >= kMaxPendingEvents) pending_.pop_front();
  pending_.push_back(json);
}

void ClipApp::announce(uint32_t now) {
  announced_ = true;
  ws_.sendText(helloJson(cfg_.device_id, enc_->codecName(), enc_->bitrate()));
  while (!pending_.empty() && ws_.isOpen()) {
    if (!ws_.sendText(pending_.front())) break;
    pending_.pop_front();
  }
  ws_.sendText(stateJson(state_, now));
  hal_.log("gateway link open");
}

void ClipApp::serviceLink(uint32_t now) {
  if (!cfg_.gateway_enabled) return;  // standalone: there is no tablet to reach
  if (!hal_.networkUp()) {
    if (ws_.state() != WsClient::State::Closed) ws_.close();
    announced_ = false;
    return;
  }

  switch (ws_.state()) {
    case WsClient::State::Closed:
      if (announced_) {
        announced_ = false;
        hal_.log("gateway link lost");
      }
      if (!tried_connect_ || (uint32_t)(now - last_attempt_) >= cfg_.reconnect_ms) {
        tried_connect_ = true;
        last_attempt_ = now;
        ws_.open(cfg_.gateway_host, cfg_.gateway_port, cfg_.gateway_path);
      }
      break;
    case WsClient::State::Handshaking:
      if ((uint32_t)(now - last_attempt_) >= cfg_.handshake_timeout_ms) ws_.close();
      break;
    case WsClient::State::Open:
      break;
  }

  std::string msg;
  for (;;) {
    bool got = ws_.poll(msg);
    if (ws_.isOpen() && !announced_) announce(now);
    if (!got) break;
    Input in;
    if (parseCommand(msg, in)) apply(in, "tablet");
  }
  if (!ws_.isOpen() && announced_) {
    announced_ = false;
    hal_.log("gateway link lost");
  }
}

void ClipApp::serviceAudio(uint32_t now) {
  if (state_ != ClipState::Listening) {
    hal_.sleepMs(10);  // mic is off: nothing to capture; avoid spinning
    return;
  }
  if (hal_.micRead(frame_, kFrameSamples) != kFrameSamples) return;
  ++stats_.frames_captured;

  uint8_t header[kAudioHeaderBytes];
  putLe32(header, audio_seq_++);
  putLe32(header + 4, now);
  size_t n = enc_->encode(frame_, kFrameSamples, packet_, sizeof packet_);
  if (n > 0 && linkOpen() && ws_.sendBinary(header, sizeof header, packet_, n)) {
    ++stats_.frames_sent;
    stats_.audio_bytes_sent += (uint32_t)n;
  } else {
    ++stats_.frames_dropped;  // no buffering of audio on the clip
  }
}

void ClipApp::refreshLed(uint32_t now, bool force) {
  LedColor want = state_ == ClipState::Listening ? LedColor::Green : LedColor::Off;

  if (flashing_) {
    if ((uint32_t)(now - flash_start_) < cfg_.marker_flash_ms) want = LedColor::White;
    else flashing_ = false;
  } else if (cfg_.gateway_enabled && state_ != ClipState::NotListening && !linkOpen() &&
             ((now / 500) % 2) == 1) {
    want = LedColor::Off;  // blinking = listening, but not connected to the tablet
  }

  if (force || want != led_) {
    led_ = want;
    hal_.setLed(want);
  }
}

}  // namespace earshot
