// Hardware abstraction. One implementation for the ESP32, one for the laptop simulator.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace earshot {

enum class LedColor : uint8_t { Off, Green, White };

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
  virtual bool networkUp() = 0;  // Wi-Fi link only: is the network there to connect over?
  virtual void log(const char* message) = 0;
};

}  // namespace earshot
