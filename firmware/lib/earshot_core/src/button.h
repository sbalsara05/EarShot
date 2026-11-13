// One-button gesture detector: short press, long press, double tap.
// Portable C++11, no Arduino dependency, so it runs on the device and in the simulator.
#pragma once
#include <stdint.h>

namespace earshot {

enum class ButtonEvent : uint8_t { None, ShortPress, LongPress, DoubleTap };

struct ButtonTiming {
  uint32_t debounce_ms;        // raw level must hold this long to count
  uint32_t long_press_ms;      // hold this long -> LongPress (fires while still held)
  uint32_t double_tap_gap_ms;  // second press must start within this gap after the first release
  ButtonTiming() : debounce_ms(30), long_press_ms(1500), double_tap_gap_ms(350) {}
};

class Button {
 public:
  explicit Button(ButtonTiming timing = ButtonTiming());

  // Call often (every 20 ms or faster) with the raw button level and the current time.
  // Returns at most one event per call.
  //  - ShortPress is reported once the double-tap window has passed with no second press.
  //  - LongPress is reported the moment the hold threshold is reached; the release is silent.
  //  - DoubleTap is reported on the release of the second tap.
  ButtonEvent update(bool raw_pressed, uint32_t now_ms);

 private:
  ButtonTiming t_;
  bool raw_last_;
  uint32_t raw_changed_at_;
  bool pressed_;
  uint32_t down_at_;
  bool long_fired_;
  bool second_tap_;
  bool tap_pending_;
  uint32_t tap_released_at_;
};

}  // namespace earshot
