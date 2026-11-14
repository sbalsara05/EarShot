// State machine for the clip.
//
//   NotListening ──"start"──▶ Listening
//        ▲                        │
//        └──────"stop", or hold───┘
//
// NotListening: mic off, nothing is captured. Ring green when a tablet is connected, a slow
//               blue blink while it waits for one.
// Listening:    mic on, audio streams to the tablet, ring red.
//
// The tablet owns the recording. A double click on the clip's button does not change the
// state here: the clip sends the tablet a "toggle" message and the tablet answers with
// "start" or "stop" (see protocol.h). The medic asks the patient for consent out loud, as they
// already do; starting is the confirmation that consent was given, and it is logged as a
// consent event before the microphone turns on.
// A single click while Listening drops a timestamp marker (a "mark"). A single click never
// starts or stops anything, so a bumped button cannot begin or cut a capture.
// A hold ends the call: while Listening it stops the capture at once, tablet or no tablet,
// and in either state the clip then sends the tablet an "end" message.
// The tablet can also ask the clip to make itself findable ("find"): it blinks and beeps for
// a few seconds in either state, without changing state.
// A standalone clip (no tablet at all, as on the Wokwi website) toggles on a double click by
// itself; that is the only use of the DoubleTap input below.
#pragma once
#include <stdint.h>

namespace earshot {

enum class ClipState : uint8_t { NotListening, Listening };

enum class Input : uint8_t { ShortPress, LongPress, DoubleTap, CmdStart, CmdStop, CmdMarker, CmdFind };

enum class Effect : uint8_t {
  None,
  Started,  // consent logged, capture starts
  Stopped,  // capture ended
  Marker,
  Find      // blink and beep so the clip can be found; the state does not change
};

struct Transition {
  ClipState next;
  Effect effect;
};

Transition step(ClipState state, Input input);

// Wire names: "not_listening", "listening".
const char* stateName(ClipState state);

}  // namespace earshot
