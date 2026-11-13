// Consent state machine for the clip, following the PRD:
//   "press to ask consent, hold to stop"
//   ring: off = not listening, amber = asking, green = listening with consent
//
//   NotListening ──press──▶ Asking ──press (patient said yes)──▶ Listening
//        ▲                    │                                      │
//        ├──hold (a "no", logged as a refusal)──┘                    │
//        └────────────────────hold (stop)────────────────────────────┘
//
// NotListening: mic off, ring dark. Nothing is captured.
// Asking:       the medic is asking the patient. Mic still off, ring amber.
// Listening:    consent logged. Mic on, audio streams to the tablet, ring green.
// Double tap while Listening drops a timestamp marker.
// The tablet can drive the same transitions with commands (see protocol.h).
#pragma once
#include <stdint.h>

namespace earshot {

enum class ClipState : uint8_t { NotListening, Asking, Listening };

enum class Input : uint8_t {
  ShortPress,
  LongPress,
  DoubleTap,
  CmdAsk,
  CmdConsentGrant,
  CmdConsentDecline,
  CmdStop,
  CmdMarker
};

enum class Effect : uint8_t {
  None,
  Asked,     // consent ask started
  Granted,   // consent logged: capture starts
  Declined,  // the patient said no (while asking) or withdrew (while listening): capture off
  Stopped,   // the medic or the tablet ended the capture, or cancelled the ask
  Marker
};

struct Transition {
  ClipState next;
  Effect effect;
};

Transition step(ClipState state, Input input);

// Wire names: "not_listening", "asking", "listening".
const char* stateName(ClipState state);

}  // namespace earshot
