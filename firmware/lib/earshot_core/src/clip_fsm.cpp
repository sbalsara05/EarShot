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
  if (input == Input::CmdFind) return go(state, Effect::Find);  // works in either state

  switch (state) {
    case ClipState::NotListening:
      if (input == Input::DoubleTap || input == Input::CmdStart)
        return go(ClipState::Listening, Effect::Started);
      // A single click or a hold does nothing here.
      return stay(state);

    case ClipState::Listening:
      switch (input) {
        case Input::DoubleTap:
        case Input::LongPress:
        case Input::CmdStop:
          return go(ClipState::NotListening, Effect::Stopped);
        case Input::ShortPress:
        case Input::CmdMarker:
          return go(state, Effect::Marker);
        default:
          return stay(state);
      }
  }
  return stay(state);
}

const char* stateName(ClipState state) {
  switch (state) {
    case ClipState::NotListening: return "not_listening";
    case ClipState::Listening: return "listening";
  }
  return "?";
}

}  // namespace earshot
