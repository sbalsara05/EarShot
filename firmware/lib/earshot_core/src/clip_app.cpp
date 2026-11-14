#include "clip_app.h"

#include <string.h>

namespace earshot {

namespace {
const size_t kMaxPendingEvents = 32;
}

ClipApp::ClipApp(Hal& hal, Transport& transport, const ClipConfig& config, uint32_t random_seed)
    : hal_(hal),
      cfg_(config),
      own_link_(new WsLink(hal, transport, random_seed, config.gateway_host, config.gateway_port,
                           config.gateway_path, config.reconnect_ms, config.handshake_timeout_ms)),
      link_(own_link_),
      button_(config.button) {
  init();
}

ClipApp::ClipApp(Hal& hal, Link& link, const ClipConfig& config)
    : hal_(hal), cfg_(config), own_link_(NULL), link_(&link), button_(config.button) {
  init();
}

ClipApp::~ClipApp() { delete own_link_; }

void ClipApp::init() {
  state_ = ClipState::NotListening;
  announced_ = false;
  enc_ = cfg_.encoder ? cfg_.encoder : &pcm_;
  audio_seq_ = 0;
  flashing_ = false;
  flash_start_ = 0;
  finding_ = false;
  find_start_ = 0;
  beep_on_ = false;
  led_ = LedColor::Off;
  memset(frame_, 0, sizeof frame_);
  memset(packet_, 0, sizeof packet_);
}

void ClipApp::begin() {
  // Power-on state: not listening, mic off. Nothing happens until the medic presses.
  refreshLed(hal_.millis(), true);
}

void ClipApp::tick() {
  uint32_t now = hal_.millis();

  if (cfg_.poll_button) {
    ButtonEvent e = button_.update(hal_.buttonPressed(), now);
    if (e != ButtonEvent::None) onButtonEvent(e, button_.gestureStartMs());
  }

  serviceLink(now);
  serviceFind(hal_.millis());
  serviceAudio(now);
  refreshLed(hal_.millis(), false);
}

void ClipApp::onButtonEvent(ButtonEvent event) { onButtonEvent(event, hal_.millis()); }

void ClipApp::onButtonEvent(ButtonEvent event, uint32_t began_ms) {
  switch (event) {
    case ButtonEvent::ShortPress: apply(Input::ShortPress, "button", began_ms); break;
    case ButtonEvent::LongPress: {
      // A hold toggles the call. The microphone goes off here and now if it was on, tablet or
      // no tablet. Then the tablet is told, and decides: end the call that is open, or open a
      // new one. Sent directly, never queued.
      apply(Input::LongPress, "button", began_ms);
      if (!cfg_.gateway_enabled) break;  // standalone: there is no call
      if (!linkOpen()) {
        hal_.log("hold: no tablet connected, so nothing was sent about the call");
        break;
      }
      uint32_t now = hal_.millis();
      ++stats_.call_toggles;
      link_->sendText(toggleJson("call", "button", now));
      flashing_ = true;  // one white flash: the hold was taken
      flash_start_ = now;
      break;
    }
    case ButtonEvent::DoubleTap:
      if (!cfg_.gateway_enabled) {
        apply(Input::DoubleTap, "button", began_ms);  // standalone: no tablet to ask, toggle here
      } else if (!linkOpen()) {
        hal_.log("double click ignored: no tablet connected");
      } else {
        // The tablet owns the recording. Tell it about the double click, with the same message
        // whatever state the clip is in, and let it answer "start" or "stop". Sent directly,
        // never queued: a double click must not take effect minutes later after a reconnect.
        ++stats_.toggles;
        link_->sendText(toggleJson("recording", "button", began_ms));
      }
      break;
    case ButtonEvent::None: break;
  }
}

void ClipApp::apply(Input input, const char* source, uint32_t began_ms) {
  uint32_t now = hal_.millis();
  Transition tr = step(state_, input);
  state_ = tr.next;

  switch (tr.effect) {
    case Effect::None:
      return;
    case Effect::Started:
      // Starting is the medic's confirmation of consent. It is logged first; only then does
      // the microphone start.
      emit(consentJson("granted", source, now));
      if (finding_) {  // a find in progress goes quiet, and frees the speaker, before the mic turns on
        setBeep(false);
        hal_.beepDone();
      }
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
    case Effect::Marker: {
      // A mark belongs to the moment the button went down, not to now: a single click is only
      // recognised once the double-click window has passed. Step the time and the audio
      // position back by that delay (ignoring anything implausibly old).
      uint32_t age = (uint32_t)(now - began_ms);
      if (age > 3000) age = 0;
      uint32_t frames_ago = age / kFrameMs;
      uint32_t seq = audio_seq_ > frames_ago ? audio_seq_ - frames_ago : 0;
      ++stats_.markers;
      flashing_ = true;
      flash_start_ = now;
      emit(markerJson(stats_.markers, source, now - age, seq));
      return;  // state did not change
    }
    case Effect::Find:
      ++stats_.finds;
      finding_ = true;
      find_start_ = now;  // asking again while it is running restarts the timer
      hal_.log(state_ == ClipState::Listening ? "find: blinking (no beep while listening)"
                                              : "find: blinking and beeping");
      return;  // state did not change
  }
  emit(stateJson(state_, now));
}

void ClipApp::emit(const std::string& json) {
  // Events go through a queue so that none is lost, and none overtakes another, while the link
  // is down or briefly cannot take a message (consent changes and markers must all arrive).
  if (pending_.size() >= kMaxPendingEvents) pending_.pop_front();
  pending_.push_back(json);
  flushPending();
}

void ClipApp::flushPending() {
  while (!pending_.empty() && linkOpen()) {
    if (!link_->sendText(pending_.front())) break;
    pending_.pop_front();
  }
}

void ClipApp::announce(uint32_t now) {
  announced_ = true;
  link_->sendText(helloJson(cfg_.device_id, enc_->codecName(), enc_->bitrate()));
  flushPending();
  link_->sendText(stateJson(state_, now));
  hal_.log("tablet link open");
}

void ClipApp::serviceLink(uint32_t now) {
  if (!cfg_.gateway_enabled) return;  // standalone: there is no tablet to reach
  link_->service(now);

  std::string msg;
  for (;;) {
    bool got = link_->poll(msg);
    if (link_->isOpen() && !announced_) announce(now);
    if (!got) break;
    Input in;
    if (parseCommand(msg, in)) apply(in, "tablet", now);
  }
  flushPending();
  if (!link_->isOpen() && announced_) {
    announced_ = false;
    hal_.log("tablet link lost");
  }
}

void ClipApp::setBeep(bool on) {
  if (on == beep_on_) return;
  beep_on_ = on;
  hal_.beep(on);
}

void ClipApp::serviceFind(uint32_t now) {
  if (!finding_) return;
  uint32_t elapsed = (uint32_t)(now - find_start_);
  if (elapsed >= cfg_.find_ms) {
    finding_ = false;
    setBeep(false);
    hal_.beepDone();
    return;
  }
  // Short beeps, but only while the microphone is off: a beep must never end up in a
  // recording, and on the real clip the speaker and microphone share one audio chip.
  bool want = state_ != ClipState::Listening && (elapsed % cfg_.find_beep_period_ms) < cfg_.find_beep_ms;
  setBeep(want);
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
  if (n > 0 && linkOpen() && link_->sendBinary(header, sizeof header, packet_, n)) {
    ++stats_.frames_sent;
    stats_.audio_bytes_sent += (uint32_t)n;
  } else {
    ++stats_.frames_dropped;  // no buffering of audio on the clip
  }
}

void ClipApp::refreshLed(uint32_t now, bool force) {
  // What the light says:
  //   slow blue blink      not listening, no tablet: ready for one to connect. Shown after
  //                        power-on and after the tablet disconnects on purpose
  //   green                tablet connected, not listening
  //   red                  tablet connected, listening (the microphone is on)
  //   red, flashing        the tablet is gone when it should be there: it dropped out of
  //                        range, or the clip is listening with no tablet connected
  //   white flash          marker
  //   fast white blink     "find"
  // Solid red always means the microphone is on. Flashing red is the alarm: it goes back to
  // solid red or green when the tablet is back.
  // A standalone clip (no tablet to connect to) is dark when it is not listening.
  bool listening = state_ == ClipState::Listening;
  bool connected = cfg_.gateway_enabled && linkOpen();
  bool waiting = cfg_.gateway_enabled && !linkOpen();
  bool alarm = waiting && (listening || link_->lostUnexpectedly());
  LedColor base = listening ? LedColor::Red : connected ? LedColor::Green : LedColor::Off;
  LedColor want = base;

  if (flashing_ && (uint32_t)(now - flash_start_) >= cfg_.marker_flash_ms) flashing_ = false;

  if (finding_) {
    // Between blinks the light shows the state as usual, so a clip that is listening still
    // reads as listening.
    if ((((uint32_t)(now - find_start_)) / cfg_.find_blink_ms) % 2 == 0) want = LedColor::White;
  } else if (flashing_) {
    want = LedColor::White;
  } else if (alarm) {
    want = ((now / 500) % 2) == 0 ? LedColor::Red : LedColor::Off;
  } else if (waiting) {
    if ((now % cfg_.wait_period_ms) < cfg_.wait_blink_ms) want = LedColor::Blue;
  }

  if (force || want != led_) {
    led_ = want;
    hal_.setLed(want);
  }
}

}  // namespace earshot
