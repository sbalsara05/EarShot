#include "clip_app.h"

#include <string.h>

namespace earshot {

namespace {
const size_t kMaxPendingEvents = 32;
}

namespace {
// Beep patterns, in ms: beep, silence, beep...
const uint16_t kConnectedSteps[] = {1500};
const uint16_t kLongShortSteps[] = {600, 150, 150};
const uint16_t kShortLongSteps[] = {150, 150, 600};
const uint16_t kTwoShortSteps[] = {150, 150, 150};
const uint16_t kOneShortSteps[] = {150};
// Pairing mode: a short beep once a second.
const uint32_t kPairingPeriodMs = 1000;
const uint32_t kPairingBeepMs = 120;
}  // namespace

const uint16_t* cueSteps(Cue cue, size_t* count) {
  switch (cue) {
    case Cue::Connected: *count = 1; return kConnectedSteps;
    case Cue::Recording:
    case Cue::RecordingStopped: *count = 3; return kLongShortSteps;
    case Cue::Resumed: *count = 3; return kShortLongSteps;
    case Cue::Paused: *count = 3; return kTwoShortSteps;
    case Cue::Mark: break;
  }
  *count = 1;
  return kOneShortSteps;
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
  mic_on_ = false;
  cue_on_ = false;
  resumable_ = false;
  cue_ = Cue::Mark;
  cue_start_ = 0;
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
  serviceSound(hal_.millis());
  serviceAudio(hal_.millis());
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
  // A hold ends the call (or opens one), so whatever starts next is a new recording, not a
  // resume. The clip does not know the call itself; this is how it tells the two apart.
  if (input == Input::LongPress) resumable_ = false;
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
      // The start beeps play first and the microphone starts when they end (serviceSound), so
      // they are not in the recording. Without sounds the microphone starts now.
      if (cfg_.sounds) playCue(resumable_ ? Cue::Resumed : Cue::Recording);
      else startMic();
      resumable_ = false;
      break;
    case Effect::Stopped:
      hal_.micStop();
      mic_on_ = false;
      memset(frame_, 0, sizeof frame_);
      memset(packet_, 0, sizeof packet_);
      emit(consentJson("stopped", source, now));
      // A hold ends the recording and the call. Any other stop (the tablet answering a double
      // click, or its own Stop button) pauses it, and the call stays open.
      playCue(input == Input::LongPress ? Cue::RecordingStopped : Cue::Paused);
      resumable_ = input != Input::LongPress;
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
      if (input == Input::ShortPress) playCue(Cue::Mark);  // a mark from the tablet's screen is silent
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
  // One long beep says a tablet connected. Not while listening (a reconnect mid-recording): the
  // microphone would have to stop for it.
  if (state_ != ClipState::Listening) playCue(Cue::Connected);
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

void ClipApp::startMic() {
  mic_on_ = hal_.micStart();
  if (!mic_on_) hal_.log("mic failed to start");
}

void ClipApp::playCue(Cue cue) {
  if (!cfg_.sounds) return;
  // Beeps must never end up in a recording, and on the Atom the speaker and the microphone
  // share one audio chip besides. So the microphone is off while a cue plays, and back on when
  // it ends if the clip is listening (serviceSound). For a mark that is a gap of about 0.4
  // seconds in the audio, just after the click.
  if (mic_on_) {
    hal_.micStop();
    mic_on_ = false;
  }
  cue_on_ = true;  // a newer cue cuts off one still playing
  cue_ = cue;
  setBeep(false);
  // The pattern starts once the speaker is ready, so even a short beep is heard in full.
  cue_start_ = hal_.millis() + hal_.beepPrepare();
  ++stats_.cues;
}

// Pairing mode: not listening, and no tablet, after power-on or a deliberate disconnect (the
// slow blue blink). A tablet that dropped out of range is the alarm instead, and is silent.
bool ClipApp::pairing() const {
  return cfg_.gateway_enabled && !linkOpen() && state_ != ClipState::Listening &&
         !link_->lostUnexpectedly();
}

void ClipApp::serviceSound(uint32_t now) {
  // One speaker, three users, in this order: a cue, then a find, then pairing mode.
  bool want = false;
  if (cue_on_) {
    size_t n = 0;
    const uint16_t* steps = cueSteps(cue_, &n);
    if ((int32_t)(now - cue_start_) < 0) {  // the speaker is still warming up: silence
      setBeep(false);
      return;
    }
    uint32_t t = (uint32_t)(now - cue_start_);
    size_t i = 0;
    while (i < n && t >= steps[i]) t -= steps[i++];
    if (i < n) {
      setBeep(i % 2 == 0);
      return;
    }
    cue_on_ = false;  // finished
    setBeep(false);
    if (state_ == ClipState::Listening) {
      startMic();  // the board powers its speaker down first
      return;
    }
    hal_.beepDone();
  }
  if (state_ == ClipState::Listening) {
    setBeep(false);
    return;
  }
  if (finding_) {
    uint32_t elapsed = (uint32_t)(now - find_start_);
    want = (elapsed % cfg_.find_beep_period_ms) < cfg_.find_beep_ms;
  } else if (cfg_.sounds && pairing()) {
    want = (now % kPairingPeriodMs) < kPairingBeepMs;
  }
  setBeep(want);
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
    if (!cue_on_) {
      setBeep(false);
      hal_.beepDone();
    }
  }
  // The beeps themselves are in serviceSound: only while the microphone is off, since a beep
  // must never end up in a recording, and on the real clip the speaker and microphone share
  // one audio chip.
}

void ClipApp::serviceAudio(uint32_t now) {
  if (state_ != ClipState::Listening || !mic_on_) {
    hal_.sleepMs(10);  // mic is off (or paused for a cue): nothing to capture; avoid spinning
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
