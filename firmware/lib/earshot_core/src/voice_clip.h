// A stored voice recording played back as if it were the microphone, for boards that have no
// microphone (the ESP32-S3 Feather) and for tests that need real speech rather than a tone.
//
// The recording is kept as IMA ADPCM: 4 bits per sample, a quarter the size of raw audio, and
// decoded on the fly with a few integer operations. In the compression test ADPCM transcribed
// the same as raw audio, so it does not colour what the Opus encoder is given.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace earshot {

class VoiceClip {
 public:
  // `adpcm` holds two samples per byte, low nibble first, starting from predictor 0, index 0.
  VoiceClip(const uint8_t* adpcm, size_t bytes);

  void rewind();
  // Writes the next `samples` samples (16 kHz mono). Starts again from the top at the end.
  void read(int16_t* out, size_t samples);

  size_t totalSamples() const { return bytes_ * 2; }
  size_t position() const { return pos_; }

 private:
  const uint8_t* data_;
  size_t bytes_;
  size_t pos_;      // next sample index
  int32_t pred_;
  int32_t index_;
};

}  // namespace earshot
