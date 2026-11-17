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

const size_t kMaxCues = 4;
}  // namespace

const uint16_t* cueSteps(Cue cue, size_t* count) {
  *count = 0;
  switch (cue) {
    case Cue::Connected:
    case Cue::Back: *count = 1; return kConnectedSteps;
    case Cue::Recording:
    case Cue::CallEnded: *count = 3; return kLongShortSteps;
    case Cue::Resumed: *count = 3; return kShortLongSteps;
    case Cue::Paused: *count = 3; return kTwoShortSteps;
    case Cue::Mark: *count = 1; return kOneShortSteps;
    case Cue::Disconnected:
    case Cue::Lost:
    case Cue::NewCall:
    case Cue::ReportReady:
    case Cue::NoTablet: break;  // no beep for these: a voice line or nothing
  }
  return kOneShortSteps;
}

Sound cueSound(Cue cue) {
  switch (cue) {
    case Cue::Connected: return Sound::ClipConnected;
    case Cue::Back: return Sound::ClipBack;
    case Cue::Disconnected: return Sound::ClipDisconnected;
    case Cue::Lost: return Sound::ClipLost;
    case Cue::Recording:
    case Cue::Resumed: return Sound::Recording;
    case Cue::Paused: return Sound::Paused;
    case Cue::Mark: return Sound::Marked;
    case Cue::NewCall: return Sound::NewCall;
    case Cue::CallEnded: return Sound::CallEnded;
    case Cue::ReportReady: return Sound::ReportReady;
    case Cue::NoTablet: return Sound::NoTablet;
  }
  return Sound::Recording;
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
  beep_loud_ = false;
  find_sound_at_ = 0;
  mic_on_ = false;
  cue_on_ = false;
  cue_played_ = false;
  cue_ms_ = 0;
  cue_ = Cue::Mark;
  cue_start_ = 0;
  resumable_ = false;
  call_open_ = false;
  was_lost_ = false;
  gone_at_ = 0;
  report_waiting_ = false;
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
  // With no tablet to hear it, a press is answered "No tablet. Nothing recorded." (a mark while
  // listening is still stored and sent later; it says the same, since no audio is arriving).
  bool no_tablet = cfg_.gateway_enabled && !linkOpen();
  switch (event) {
    case ButtonEvent::ShortPress:
      if (no_tablet && state_ != ClipState::Listening) playCue(Cue::NoTablet);
      apply(Input::ShortPress, "button", began_ms);
      break;
    case ButtonEvent::LongPress: {
      // A hold toggles the call. The microphone goes off here and now if it was on, tablet or
      // no tablet. Then the tablet is told, and decides: end the call that is open, or open a
      // new one. Sent directly, never queued.
      bool was_listening = state_ == ClipState::Listening;
      apply(Input::LongPress, "button", began_ms);
      if (!cfg_.gateway_enabled) {  // standalone: there is no call
        if (was_listening) playCue(Cue::CallEnded);
        break;
      }
      if (no_tablet) {
        hal_.log("hold: no tablet connected, so nothing was sent about the call");
        playCue(Cue::NoTablet);
        break;
      }
      // The clip cannot see the call, so it goes by what it has seen: a recording since the last
      // hold means a call is open and this hold ends it; otherwise this hold opens one.
      bool ending = was_listening || call_open_;
      call_open_ = !ending;
      playCue(ending ? Cue::CallEnded : Cue::NewCall);
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
      } else if (no_tablet) {
        hal_.log("double click ignored: no tablet connected");
        playCue(Cue::NoTablet);
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
  if (input == Input::CmdReportReady) {
    // The tablet finished the report for a call. Said now, or once the microphone is off if a
    // recording is running, so it never cuts into one.
    if (state_ == ClipState::Listening) report_waiting_ = true;
    else playCue(Cue::ReportReady);
    return;
  }
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
      // The cue plays first and the microphone starts when it ends (serviceSound), so it is not
      // in the recording. Without sounds the microphone starts now.
      call_open_ = true;
      playCue(resumable_ ? Cue::Resumed : Cue::Recording);
      resumable_ = false;
      if (!cue_on_) startMic();
      break;
    case Effect::Stopped:
      hal_.micStop();
      mic_on_ = false;
      memset(frame_, 0, sizeof frame_);
      memset(packet_, 0, sizeof packet_);
      emit(consentJson("stopped", source, now));
      // A hold ends the recording and the call. Any other stop (the tablet answering a double
      // click, or its own Stop button) pauses it, and the call stays open.
      // A hold is announced by onButtonEvent ("call ended", or "no tablet"). Any other stop (the
      // tablet answering a double click, or its own Stop button) pauses, and the call stays open.
      if (input != Input::LongPress) playCue(Cue::Paused);
      resumable_ = input != Input::LongPress;
      if (report_waiting_) {
        report_waiting_ = false;
        playCue(Cue::ReportReady);
      }
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
      // The beeps wait for the speaker to warm up, so the first is heard in full. None while
      // listening: they would land in the recording.
      find_sound_at_ = now + (state_ == ClipState::Listening ? 0 : hal_.beepPrepare());
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
  playCue(was_lost_ ? Cue::Back : Cue::Connected);
  was_lost_ = false;
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
    was_lost_ = link_->lostUnexpectedly();
    gone_at_ = now;
    hal_.log(was_lost_ ? "tablet link lost" : "tablet disconnected");
    playCue(was_lost_ ? Cue::Lost : Cue::Disconnected);
  }
  // Recording with no tablet to hear it: the clip waits as long as the app does for the tablet
  // to come back, then stops ("Paused"; the call stays open on the tablet) and goes back to
  // pairing mode. The tablet sees the stop when it reconnects.
  if (state_ == ClipState::Listening && !linkOpen() && (uint32_t)(now - gone_at_) >= cfg_.lost_grace_ms) {
    hal_.log("no tablet while recording for too long: recording stopped, back to pairing mode");
    apply(Input::CmdStop, "clip", now);
  }
}

void ClipApp::startMic() {
  mic_on_ = hal_.micStart();
  if (!mic_on_) hal_.log("mic failed to start");
}

void ClipApp::playCue(Cue cue) {
  if (!cfg_.sounds) return;
  size_t steps = 0;
  cueSteps(cue, &steps);
  if (hal_.soundMs(cueSound(cue)) == 0 && steps == 0) return;  // nothing to play on this board
  if (cues_.size() >= kMaxCues) return;
  cues_.push_back(cue);  // each one plays in full, in order: "new call", then "recording"
  ++stats_.cues;
  if (!cue_on_) startNextCue();
}

void ClipApp::startNextCue() {
  cue_ = cues_.front();
  cues_.pop_front();
  cue_on_ = true;
  cue_played_ = false;
  cue_ms_ = 0;
  // Nothing the clip says may end up in a recording, and on the Atom the speaker and the
  // microphone share one audio chip besides. So the microphone is off while a cue plays, and
  // back on when the last one ends if the clip is listening (serviceSound). For a mark that is
  // a gap of about a second in the audio, just after the click.
  if (mic_on_) {
    hal_.micStop();
    mic_on_ = false;
  }
  setBeep(false);
  // The cue starts once the speaker is ready, so even a short one is heard in full.
  cue_start_ = hal_.millis() + hal_.beepPrepare();
}

// Pairing mode: not listening, and no tablet: after power-on, after a disconnect of any kind,
// and after a recording outlived a lost tablet (the slow blue blink, a beep every second).
// The clip advertises all the while, so the tablet can find it again.
bool ClipApp::pairing() const {
  return cfg_.gateway_enabled && !linkOpen() && state_ != ClipState::Listening;
}

void ClipApp::serviceSound(uint32_t now) {
  // One speaker, three users, in this order: a cue, then a find, then pairing mode.
  bool want = false;
  if (cue_on_) {
    if ((int32_t)(now - cue_start_) < 0) {  // the speaker is still warming up: silence
      setBeep(false);
      return;
    }
    if (!cue_played_) {
      cue_played_ = true;
      cue_ms_ = hal_.soundMs(cueSound(cue_));
      if (cue_ms_ > 0) hal_.playSound(cueSound(cue_));
    }
    uint32_t t = (uint32_t)(now - cue_start_);
    if (cue_ms_ > 0) {
      if (t < cue_ms_) return;  // the voice line is playing
    } else {
      size_t n = 0;
      const uint16_t* steps = cueSteps(cue_, &n);
      size_t i = 0;
      while (i < n && t >= steps[i]) t -= steps[i++];
      if (i < n) {
        setBeep(i % 2 == 0);
        return;
      }
    }
    cue_on_ = false;  // finished
    setBeep(false);
    if (!cues_.empty()) {
      startNextCue();
      return;
    }
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
    // Find: loud, fast beeps, so the clip can be found under a seat or in a pile of kit.
    if ((int32_t)(now - find_sound_at_) < 0) {
      setBeep(false);
      return;
    }
    uint32_t elapsed = (uint32_t)(now - find_sound_at_);
    setBeep((elapsed % cfg_.find_beep_period_ms) < cfg_.find_beep_ms, true);
    return;
  } else if (cfg_.sounds && pairing()) {
    want = (now % kPairingPeriodMs) < kPairingBeepMs;
  }
  setBeep(want);
}

void ClipApp::setBeep(bool on, bool loud) {
  if (on && loud != beep_loud_) {  // switching between the gentle and the loud beep
    if (beep_on_) hal_.beep(false);
    beep_on_ = false;
    beep_loud_ = loud;
    hal_.beepLoud(loud);
  }
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
  //   slow blue blink      pairing mode: not listening, no tablet, ready for one to connect.
  //                        After power-on and after any disconnect, deliberate or lost
  //   green                tablet connected, not listening
  //   red                  tablet connected, listening (the microphone is on)
  //   red, flashing        listening with no tablet: it dropped out mid-recording. Lasts until
  //                        it is back, or for lost_grace_ms, then the recording stops and the
  //                        clip goes back to pairing mode
  //   white flash          marker
  //   fast white blink     "find"
  // Solid red always means the microphone is on. Flashing red is the alarm.
  // A standalone clip (no tablet to connect to) is dark when it is not listening.
  bool listening = state_ == ClipState::Listening;
  bool connected = cfg_.gateway_enabled && linkOpen();
  bool waiting = cfg_.gateway_enabled && !linkOpen();
  bool alarm = waiting && listening;
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
