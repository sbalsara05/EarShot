// State machine for the clip: press to start, hold to stop.
//
//   NotListening ──press──▶ Listening
//        ▲                      │
//        └────────hold──────────┘
//
// NotListening: mic off, ring dark. Nothing is captured.
// Listening:    mic on, audio streams to the tablet, ring green.
//
// The medic asks the patient for consent out loud, as they already do. Pressing the button is
// the medic's confirmation that consent was given: the press is logged as a consent event and
// only then does capture start. If the patient says no, the medic does not press.
// Double tap while Listening drops a timestamp marker.
// The tablet can drive the same transitions with commands (see protocol.h).
#pragma once
#include <stdint.h>

namespace earshot {

enum class ClipState : uint8_t { NotListening, Listening };

enum class Input : uint8_t { ShortPress, LongPress, DoubleTap, CmdStart, CmdStop, CmdMarker };

enum class Effect : uint8_t {
  None,
  Started,  // consent logged, capture starts
  Stopped,  // capture ended
  Marker
};

struct Transition {
  ClipState next;
  Effect effect;
};

Transition step(ClipState state, Input input);

// Wire names: "not_listening", "listening".
const char* stateName(ClipState state);

}  // namespace earshot
