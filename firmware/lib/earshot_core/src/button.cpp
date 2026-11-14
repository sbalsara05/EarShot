#include "button.h"

namespace earshot {

Button::Button(ButtonTiming timing)
    : t_(timing),
      raw_last_(false),
      raw_changed_at_(0),
      pressed_(false),
      down_at_(0),
      gesture_at_(0),
      long_fired_(false),
      second_tap_(false),
      tap_pending_(false),
      tap_released_at_(0) {}

ButtonEvent Button::update(bool raw, uint32_t now) {
  // Debounce: accept a level change only after it has been stable for debounce_ms.
  if (raw != raw_last_) {
    raw_last_ = raw;
    raw_changed_at_ = now;
  }
  bool edge = false;
  if (raw != pressed_ && (uint32_t)(now - raw_changed_at_) >= t_.debounce_ms) {
    pressed_ = raw;
    edge = true;
  }

  if (edge && pressed_) {  // press
    down_at_ = now;
    long_fired_ = false;
    second_tap_ = tap_pending_;  // pressed again inside the double-tap window
    tap_pending_ = false;
    if (!second_tap_) gesture_at_ = now;  // a second tap belongs to the gesture already begun
    return ButtonEvent::None;
  }

  if (pressed_ && !long_fired_ && (uint32_t)(now - down_at_) >= t_.long_press_ms) {
    long_fired_ = true;
    second_tap_ = false;  // tap-then-hold counts as a long press only
    return ButtonEvent::LongPress;
  }

  if (edge && !pressed_) {  // release
    if (long_fired_) return ButtonEvent::None;
    if (second_tap_) {
      second_tap_ = false;
      return ButtonEvent::DoubleTap;
    }
    tap_pending_ = true;
    tap_released_at_ = now;
    return ButtonEvent::None;
  }

  if (tap_pending_ && !pressed_ &&
      (uint32_t)(now - tap_released_at_) >= t_.double_tap_gap_ms) {
    tap_pending_ = false;
    return ButtonEvent::ShortPress;
  }

  return ButtonEvent::None;
}

}  // namespace earshot
