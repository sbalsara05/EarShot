// The step between the microphone and the link: turns one 20 ms frame of samples into the
// bytes that are sent. Raw PCM is built in; Opus lives in lib/earshot_opus so the core has no
// dependency on the codec library.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace earshot {

class AudioEncoder {
 public:
  virtual ~AudioEncoder() {}
  virtual const char* codecName() const = 0;  // "pcm" or "opus": tells the tablet how to decode
  virtual uint32_t bitrate() const = 0;       // audio bits per second on the wire
  virtual void reset() = 0;                   // called at the start of every capture
  // Encodes one frame into `out`. Returns the number of bytes written, or 0 on failure.
  virtual size_t encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t out_max) = 0;
};

// Uncompressed 16-bit little-endian samples: 640 bytes per 20 ms frame, 32,000 bytes per second.
class PcmEncoder : public AudioEncoder {
 public:
  const char* codecName() const override { return "pcm"; }
  uint32_t bitrate() const override { return 16000u * 16u; }
  void reset() override {}
  size_t encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t out_max) override {
    if (samples * 2 > out_max) return 0;
    for (size_t i = 0; i < samples; ++i) {
      out[2 * i] = (uint8_t)(pcm[i] & 0xFF);
      out[2 * i + 1] = (uint8_t)((pcm[i] >> 8) & 0xFF);
    }
    return samples * 2;
  }
};

}  // namespace earshot
