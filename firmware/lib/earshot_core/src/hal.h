// Hardware abstraction. One implementation for the ESP32, one for the laptop simulator.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace earshot {

enum class LedColor : uint8_t { Off, Green, White, Blue, Red };

class Hal {
 public:
  virtual ~Hal() {}
  virtual uint32_t millis() = 0;
  virtual void sleepMs(uint32_t ms) = 0;
  virtual bool buttonPressed() = 0;
  virtual void setLed(LedColor color) = 0;
  virtual bool micStart() = 0;
  virtual void micStop() = 0;
  // Fills `out` with exactly `samples` samples and returns `samples`, or returns 0 if a full
  // frame is not ready. May block for up to one frame (20 ms); that paces the main loop.
  virtual size_t micRead(int16_t* out, size_t samples) = 0;
  // The clip's beeps: "find me", pairing mode and the button sounds. beep(true) starts a tone
  // that lasts until beep(false). The app only asks while the microphone is off. beepDone()
  // follows the last beep of a find, so a board can power its speaker down. Boards with no
  // speaker do nothing.
  virtual void beep(bool on) = 0;
  virtual void beepDone() {}
  // Powers the speaker up ahead of a beep pattern and returns how long it needs before a beep is
  // heard (the Atom resets its audio chip and switches its amplifier on, and the first moments
  // after that are lost). 0 when it is already on, or the board has nothing to prepare.
  virtual uint32_t beepPrepare() { return 0; }
  virtual bool networkUp() = 0;  // Wi-Fi link only: is the network there to connect over?
  virtual void log(const char* message) = 0;
};

}  // namespace earshot
