// Opus encoder for the clip's audio: 16 kHz mono speech, one packet per 20 ms frame.
//
// At 32 kbit/s every packet is 80 bytes, so the stream is 4,000 bytes per second: an eighth of
// raw PCM, and half of the ~8,000 bytes per second a Bluetooth link to iOS can carry.
// Constant bitrate keeps that budget predictable. The same code runs on the ESP32 and in the
// laptop simulator.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "audio_encoder.h"

struct OpusEncoder;

namespace earshot {

class OpusAudioEncoder : public AudioEncoder {
 public:
  // complexity is Opus's CPU-versus-quality knob (0-10). 1 is what the accuracy test used and
  // is light enough for the ESP32 to keep up in real time.
  explicit OpusAudioEncoder(uint32_t bitrate_bps = 32000, int complexity = 1);
  ~OpusAudioEncoder() override;

  bool ok() const { return enc_ != NULL; }

  const char* codecName() const override { return "opus"; }
  uint32_t bitrate() const override { return bitrate_; }
  void reset() override;
  size_t encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t out_max) override;

  // Longest time one encode() call has taken, in microseconds (0 where there is no clock).
  // On the device this must stay well under 20,000 for the clip to keep up.
  uint32_t maxEncodeMicros() const { return max_us_; }

 private:
  OpusEncoder* enc_;
  uint32_t bitrate_;
  uint32_t max_us_;
};

}  // namespace earshot
