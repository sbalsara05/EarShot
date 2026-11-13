#include "clip_fsm.h"

namespace earshot {

static Transition stay(ClipState s) {
  Transition t = {s, Effect::None};
  return t;
}

static Transition go(ClipState s, Effect e) {
  Transition t = {s, e};
  return t;
}

Transition step(ClipState state, Input input) {
  switch (state) {
    case ClipState::NotListening:
      switch (input) {
        case Input::ShortPress:
        case Input::CmdAsk:
          return go(ClipState::Asking, Effect::Asked);
        case Input::CmdConsentGrant:  // the tablet handled the consent conversation itself
          return go(ClipState::Listening, Effect::Granted);
        default:
          return stay(state);
      }

    case ClipState::Asking:
      switch (input) {
        case Input::ShortPress:
        case Input::CmdConsentGrant:
          return go(ClipState::Listening, Effect::Granted);
        case Input::LongPress:
        case Input::CmdConsentDecline:
          return go(ClipState::NotListening, Effect::Declined);
        case Input::CmdStop:
          return go(ClipState::NotListening, Effect::Stopped);
        default:
          return stay(state);
      }

    case ClipState::Listening:
      switch (input) {
        case Input::LongPress:
        case Input::CmdStop:
          return go(ClipState::NotListening, Effect::Stopped);
        case Input::CmdConsentDecline:  // the patient withdrew mid-call
          return go(ClipState::NotListening, Effect::Declined);
        case Input::DoubleTap:
        case Input::CmdMarker:
          return go(state, Effect::Marker);
        default:
          // A short press while already listening is ignored on purpose, so a bumped
          // button cannot cut the capture mid-call. Hold is the way to stop.
          return stay(state);
      }
  }
  return stay(state);
}

const char* stateName(ClipState state) {
  switch (state) {
    case ClipState::NotListening: return "not_listening";
    case ClipState::Asking: return "asking";
    case ClipState::Listening: return "listening";
  }
  return "?";
}

}  // namespace earshot
